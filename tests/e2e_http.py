"""HTTP checks of tests/e2e.sh, from the Docker host, as a browser would make them.

Talks to MISP_HOSTNAME through the reverse proxy of the test (its address is
given, there is no DNS record), and to misp-nginx on its LAN address. Prints
"PASS<tab>what" or "FAIL<tab>what<tab>detail" lines (see py_checks in
tests/lib.sh). Python standard library only.

    python3 tests/e2e_http.py HOSTNAME PROXY_IP LAN_IP HTTPS_PORT HTTP_PORT \
        ADMIN_EMAIL ADMIN_PASSWORD ADMIN_KEY CORE_TAG
"""

import html
import http.client
import json
import re
import ssl
import sys
import urllib.parse

(HOSTNAME, PROXY_IP, LAN_IP, HTTPS_PORT, HTTP_PORT, ADMIN_EMAIL, ADMIN_PASSWORD, ADMIN_KEY,
 CORE_TAG) = sys.argv[1:10]

# Both the reverse proxy of the test and misp-nginx have self-signed certificates.
CONTEXT = ssl.create_default_context()
CONTEXT.check_hostname = False
CONTEXT.verify_mode = ssl.CERT_NONE


def result(ok, what, detail=""):
    line = ("PASS" if ok else "FAIL") + "\t" + what
    if not ok:
        line += "\t" + str(detail).replace("\t", " ").replace("\n", "\\n")[:3000]
    print(line, flush=True)
    return ok


class Browser:
    """Just enough of a browser: one host, cookies by name, no automatic redirects."""

    def __init__(self, address, port, host, https=True):
        self.address, self.port, self.host, self.https = address, port, host, https
        self.cookies = {}

    def request(self, method, path, body=None, headers=None):
        if self.https:
            conn = http.client.HTTPSConnection(self.address, self.port, context=CONTEXT, timeout=120)
        else:
            conn = http.client.HTTPConnection(self.address, self.port, timeout=120)
        sent = {"Host": self.host, "User-Agent": "misp-zsazsa-e2e", "Accept": "text/html,*/*",
                "Sec-Fetch-Mode": "navigate"}
        if self.cookies:
            sent["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        sent.update(headers or {})
        try:
            conn.request(method, path, body=body, headers=sent)
            response = conn.getresponse()
            text = response.read().decode(errors="replace")
        finally:
            conn.close()
        for cookie in response.headers.get_all("Set-Cookie") or []:
            name, _, rest = cookie.partition("=")
            value = rest.split(";", 1)[0]
            if re.search(r";\s*Max-Age=0\b", cookie, re.I) or value in ("", "deleted"):
                self.cookies.pop(name.strip(), None)
            else:
                self.cookies[name.strip()] = value
        return response.status, response.headers, text

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def follow(self, path, limit=10):
        """GET and follow redirects on this host; returns the last response and its path."""
        for _ in range(limit):
            status, headers, text = self.get(path)
            location = headers.get("Location")
            if status not in (301, 302, 303, 307, 308) or not location:
                return status, headers, text, path
            url = urllib.parse.urlsplit(location)
            if url.netloc and url.hostname != self.host:
                return status, headers, text, path
            path = url.path + (f"?{url.query}" if url.query else "")
        return status, headers, text, path


def location(headers):
    return headers.get("Location") or ""


def check(what, func):
    try:
        func()
    except Exception as error:  # a check that cannot even run fails, the next ones still run
        result(False, what, f"{type(error).__name__}: {error}")


proxy = Browser(PROXY_IP, 443, HOSTNAME)


def misp_through_proxy():
    status, _, text = proxy.get("/users/login")
    result(status == 200 and "data[User][email]" in text,
           "MISP's login page through the reverse proxy", f"HTTP {status}")


def misp_on_lan():
    status, _, text = Browser(LAN_IP, int(HTTPS_PORT), HOSTNAME).get("/users/login")
    result(status == 200 and "data[User][email]" in text,
           f"misp-nginx answers on MISP_LAN_IP:{HTTPS_PORT}", f"HTTP {status}")
    status, headers, _ = Browser(LAN_IP, int(HTTP_PORT), HOSTNAME, https=False).get("/users/login")
    result(status in (301, 302, 308) and location(headers).startswith(f"https://{HOSTNAME}"),
           f"MISP_HTTP_PORT {HTTP_PORT} redirects to https://{HOSTNAME}", f"HTTP {status} {location(headers)}")


def misp_api():
    status, _, text = proxy.get("/servers/getVersion", headers={
        "Authorization": ADMIN_KEY, "Accept": "application/json"})
    version = json.loads(text).get("version", "") if status == 200 else text[:300]
    result(status == 200 and version == CORE_TAG.lstrip("v"),
           f"MISP API answers with the admin key, version {CORE_TAG.lstrip('v')}", f"HTTP {status} {version}")


def zsazsa_without_session():
    browser = Browser(PROXY_IP, 443, HOSTNAME)
    status, headers, _ = browser.get("/zsazsa")
    result(status == 301 and location(headers) == "/zsazsa/", "/zsazsa redirects to /zsazsa/",
           f"HTTP {status} {location(headers)}")
    status, headers, _ = browser.get("/zsazsa/")
    result(status in (302, 303) and location(headers) == "/zsazsa-login/zsazsa/",
           "zsazsa without a MISP session goes to /zsazsa-login/ (05-zsazsa.sh rewrites the redirect)",
           f"HTTP {status} {location(headers)}")
    status, headers, _ = browser.get("/zsazsa-login/zsazsa/")
    result(status == 302 and location(headers) == "/users/login" and browser.cookies.get("zsazsa_return") == "/zsazsa/",
           "/zsazsa-login/ remembers the page and shows MISP's login",
           f"HTTP {status} {location(headers)} cookies {sorted(browser.cookies)}")


def login_and_single_sign_on():
    """The way back to zsazsa after a MISP login, and zsazsa knowing the user."""
    browser = Browser(PROXY_IP, 443, HOSTNAME)
    browser.get("/zsazsa/")
    browser.get("/zsazsa-login/zsazsa/")
    status, _, text = browser.get("/users/login")
    form = re.search(r'<form[^>]*action="[^"]*/users/login"[^>]*>(.*?)</form>', text, re.S)
    if not result(status == 200 and form is not None, "MISP's login form", f"HTTP {status}"):
        return
    fields = {}
    for tag in re.findall(r"<input[^>]*>", form.group(1)):
        name = re.search(r'name="([^"]+)"', tag)
        value = re.search(r'value="([^"]*)"', tag)
        if name:
            fields[html.unescape(name.group(1))] = html.unescape(value.group(1)) if value else ""
    fields["data[User][email]"] = ADMIN_EMAIL
    fields["data[User][password]"] = ADMIN_PASSWORD
    status, headers, text = browser.request(
        "POST", "/users/login", body=urllib.parse.urlencode(fields),
        headers={"Content-Type": "application/x-www-form-urlencoded", "Origin": f"https://{HOSTNAME}",
                 "Referer": f"https://{HOSTNAME}/users/login"})
    after = urllib.parse.urlsplit(location(headers)).path
    if not result(status == 302 and after != "/users/login", "logging in to MISP as the administrator",
                  f"HTTP {status} {location(headers)} {re.sub(r'<[^>]+>', ' ', text)[:500]}"):
        return
    status, headers, _ = browser.get(after)
    if after == "/users/routeafterlogin":
        result(status == 302 and location(headers) == "/zsazsa/",
               "after the login MISP's route goes back to the zsazsa page", f"HTTP {status} {location(headers)}")
    else:
        result(False, "after the login MISP's route goes back to the zsazsa page",
               f"MISP sent the browser to {after}, not /users/routeafterlogin")
    status, _, text, path = browser.follow("/zsazsa/")
    user = re.search(r'class="topbar-user"[^>]*>(.*?)</span>', text, re.S)
    shown = re.sub(r"<[^>]+>", "", user.group(1)).strip() if user else None
    result(status == 200 and path.startswith("/zsazsa/") and shown == ADMIN_EMAIL,
           "single sign-on: zsazsa shows the MISP user", f"HTTP {status} at {path}, user shown: {shown}")
    result('/zsazsa/static/' in text, "zsazsa links its static files under /zsazsa/ (X-Forwarded-Prefix)",
           "no /zsazsa/static/ in the page")
    status, _, text = browser.get("/zsazsa/static/favicon.svg")
    result(status == 200 and "<svg" in text, "zsazsa's static files through misp-nginx", f"HTTP {status}")
    # And MISP itself still works with the same session.
    status, _, text = browser.get("/events/index")
    result(status == 200 and "logout" in text.lower(), "MISP's event list with the same session", f"HTTP {status}")


check("MISP through the reverse proxy", misp_through_proxy)
check("misp-nginx on the LAN", misp_on_lan)
check("MISP API", misp_api)
check("zsazsa without a session", zsazsa_without_session)
check("MISP login and single sign-on", login_and_single_sign_on)
