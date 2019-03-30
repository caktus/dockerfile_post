"Run some basic tests against the docker-compose app"
import logging
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

logging.basicConfig(level=logging.DEBUG)

BASE_URL = 'http://localhost:8000/'

s = requests.Session()

# uWSGI should return a 400 error for requests with a bad Host header
r = s.get(urljoin(BASE_URL, ''), headers={'Host': 'badhost.com'})
assert r.status_code == 400, r.status_code
# uWSGI just returns an empty response. If the request makes it to Django
# (which it shouldn't), this will be b'<h1>Bad Request (400)</h1>'.
assert r.content == b'', r.content

# Our project doesn't have a homepage URL
r = s.get(urljoin(BASE_URL, ''))
assert r.status_code == 404, r.status_code

# We should still be able to get to the admin
r = s.get(urljoin(BASE_URL, 'admin/'))
assert r.status_code == 200, r.status_code

# Which, in turn, should have some CSS files we can try to download
soup = BeautifulSoup(r.content, features="html.parser")
for link_href in [l.get('href') for l in soup.find_all('link')]:
    # If static files fail to download, uWSGI must not be set up properly to
    # serve them.
    r = s.get(urljoin(BASE_URL, link_href))
    assert r.status_code == 200, \
        'r.status_code=%s, link_href=%s' % (r.status_code, link_href)
    # If there's no 'Expires' header, uWSGI probably didn't get built with
    # regexp support (likely due to a missing system package).
    assert 'Expires' in r.headers, \
        'r.headers=%s, link_href=%s' % (r.headers, link_href)
