#!/usr/bin/env python3
"""
DigitalPlat API helper — bypasses Cloudflare challenge via cloudscraper.
Called by renew-digitalplat-subdomains.sh to fetch API data.

Usage: python3 digitalplat_api_helper.py <endpoint> <auth_token>
  endpoint: e.g. /domains
  auth_token: Bearer token (already includes 'Bearer ')

Output: JSON response on stdout, errors on stderr, exit code 0/1.
"""

import sys
import json
import os
import urllib.request
import urllib.error

try:
    import cloudscraper
    HAS_CLOUDSCRAPER = True
except ImportError:
    HAS_CLOUDSCRAPER = False

API_BASE = "https://domain-api.digitalplat.org/api/v1"

def fetch_with_cloudscraper(url, headers):
    """Use cloudscraper to bypass Cloudflare challenge."""
    scraper = cloudscraper.create_scraper(
        browser={'browser': 'chrome', 'platform': 'linux', 'desktop': True}
    )
    response = scraper.get(url, headers=headers, timeout=30)
    if response.status_code != 200:
        print(f"Error: HTTP {response.status_code}", file=sys.stderr)
        print(response.text[:500], file=sys.stderr)
        sys.exit(1)
    return response.text

def fetch_with_urllib(url, headers):
    """Fallback: standard urllib (no Cloudflare bypass)."""
    req = urllib.request.Request(url)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.read().decode('utf-8')
    except urllib.error.HTTPError as e:
        print(f"Error: HTTP {e.code}", file=sys.stderr)
        print(e.read().decode('utf-8', errors='replace')[:500], file=sys.stderr)
        sys.exit(1)

def main():
    if len(sys.argv) < 3:
        print("Usage: digitalplat_api_helper.py <endpoint> <auth_token>", file=sys.stderr)
        sys.exit(1)

    endpoint = sys.argv[1]
    auth_token = sys.argv[2]
    url = f"{API_BASE}{endpoint}"
    headers = {"Authorization": auth_token, "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"}

    if HAS_CLOUDSCRAPER:
        body = fetch_with_cloudscraper(url, headers)
    else:
        print("Warning: cloudscraper not installed, falling back to urllib (may fail on Cloudflare)", file=sys.stderr)
        body = fetch_with_urllib(url, headers)

    # Validate JSON
    try:
        json.loads(body)
    except json.JSONDecodeError:
        print(f"Error: Response is not valid JSON", file=sys.stderr)
        print(body[:500], file=sys.stderr)
        sys.exit(1)

    print(body)

if __name__ == "__main__":
    main()
