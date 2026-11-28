"""Loaded by Python at every start in zsazsa's containers, through PYTHONPATH in
deploy/zsazsa.override.yml.

zsazsa pins PyMISP below 3 on purpose, while MISP recommends 3.0.0, so PyMISP
logs a version warning for every connection: in the logs, and in the output of
the migrations on the Settings page. This drops that one message; PyMISP's other
messages are kept. misp-scraper silences PyMISP's logging by itself.
"""
import logging


class _NoVersionAdvice(logging.Filter):
    def filter(self, record):
        return "recommended by the MISP instance" not in record.getMessage()


logging.getLogger("pymisp").addFilter(_NoVersionAdvice())
