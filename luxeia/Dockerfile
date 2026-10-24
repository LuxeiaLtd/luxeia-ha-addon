# The Luxeia add-on. Small and plain: Home Assistant's base image, curl,
# openssl (to check signatures) and Python (the updater reads the update
# server's answers with it, and serve.py is the web server).
ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache openssl python3

# Copied in by scripts/package-addon.sh: the same updater and keys homes use
COPY run.sh serve.py check-update.sh verify-build.sh opener.html display-opener.html opener.js config.yaml /opt/luxeia/
COPY keys/ /opt/luxeia/keys/
# The touch display app's build keys (none until it has one: then nothing is installed for it)
COPY display-keys/ /opt/luxeia/display-keys/
COPY approval-keys/ /opt/luxeia/approval-keys/
RUN chmod a+x /opt/luxeia/*.sh

CMD ["/opt/luxeia/run.sh"]
