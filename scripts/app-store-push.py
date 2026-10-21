#!/usr/bin/env python3
"""Push the store copy and screenshots kept in this repository to App Store Connect.

    scripts/app-store-push.py check                  the copy's lengths and the pictures, without signing in
    scripts/app-store-push.py status                 what App Store Connect has now
    scripts/app-store-push.py copy [--dry-run]       promotional text, keywords, description, What's New
    scripts/app-store-push.py screenshots [--dry-run]  the iPhone and iPad sets; only pictures that differ are sent
    scripts/app-store-push.py notes [--dry-run]      the notes for App Review, with the test key put in
    scripts/app-store-push.py all [--dry-run]        copy and screenshots (not the notes)

The copy is read from docs/app-store-listing.md (the sections named for those four fields, the
What's New being the one for the version in project.yml) and the pictures from
design/screenshots/, in the order listed below. The version has to be editable in App Store
Connect; one that isn't there yet is made.

The review notes are the block in docs/app-review-notes.md with its <<REVIEW KEY>> replaced by
the test key: ASC_REVIEW_KEY if that is set (environment or tmp/asc.env), or else the key in the
newest notes App Store Connect holds that have one. The key is never printed. (Found 2026-10-13:
the notes of every version from 1.1 to 1.7.1 had gone in with the placeholder still in them.)

It needs an App Store Connect API key with the App Manager role: ASC_KEY_ID, ASC_ISSUER_ID and
ASC_KEY_PATH (the .p8 file), in the environment or as KEY=value lines in tmp/asc.env, which
.gitignore lists. The key is only read to sign a token; nothing here stores or prints it.

First run for real on 2026-10-13, for 1.8: `status`, then `copy` (which made the version and
sent three fields), then `screenshots` (which sent the one picture that had changed and left
the other eighteen alone). `status` changes nothing and says what a push would do. Not yet run:
a set of a different length from the one in App Store Connect, which is deleted and sent whole.
"""
import base64, hashlib, json, os, re, subprocess, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE = 'com.goosehouse.echo'
API = 'https://api.appstoreconnect.apple.com'
LOCALE = 'en-US'
# Folder, the display type App Store Connect files it under, and the upload order.
SETS = [
    ('iphone-6.9', 'APP_IPHONE_67', ['pano-01a', 'pano-01b', '03-bots', '04-crew', '05-work', '06-rich',
                                    '07-backend', '08-car', '09-tools', '10-privacy']),
    ('ipad-13', 'APP_IPAD_PRO_3GEN_129', ['pano-01a', 'pano-01b', '03-ipad-bots', '04-ipad-crew', '05-ipad-work',
                                          '06-ipad-rich', '07-ipad-backend', '08-ipad-tools', '09-ipad-privacy']),
]
LIMITS = {'promotionalText': 170, 'keywords': 100, 'description': 4000, 'whatsNew': 4000}


def credentials():
    found = {k: os.environ.get(k) for k in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH')}
    path = os.path.join(ROOT, 'tmp', 'asc.env')
    if os.path.exists(path):
        for line in open(path):
            if '=' in line and not line.lstrip().startswith('#'):
                key, value = line.split('=', 1)
                key = key.replace('export', '').strip()
                if key in found and not found[key]:
                    found[key] = value.strip().strip('"\'')
    missing = [k for k, v in found.items() if not v]
    if missing:
        sys.exit(f"Missing {', '.join(missing)}: set them in the environment or in tmp/asc.env (see the top of this script).")
    found['ASC_KEY_PATH'] = os.path.expanduser(found['ASC_KEY_PATH'])
    if not os.path.exists(found['ASC_KEY_PATH']):
        sys.exit(f"No key file at {found['ASC_KEY_PATH']}")
    return found


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


_token = {'value': None, 'until': 0}


def token():
    """An ES256 token good for twenty minutes, signed by openssl so no Python package is needed."""
    if _token['value'] and time.time() < _token['until'] - 60:
        return _token['value']
    c = credentials()
    now = int(time.time())
    head = b64url(json.dumps({'alg': 'ES256', 'kid': c['ASC_KEY_ID'], 'typ': 'JWT'}).encode())
    body = b64url(json.dumps({'iss': c['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'}).encode())
    signing = f'{head}.{body}'.encode()
    der = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', c['ASC_KEY_PATH']], input=signing, capture_output=True, check=True).stdout
    # openssl answers in DER (a sequence of two integers); a token wants the two as 32 bytes each.
    def integer(at):
        assert der[at] == 0x02
        length = der[at + 1]
        return int.from_bytes(der[at + 2: at + 2 + length], 'big'), at + 2 + length
    start = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)
    r, after = integer(start)
    s, _ = integer(after)
    _token.update(value=f'{head}.{body}.{b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))}', until=now + 1200)
    return _token['value']


def api(method, path, body=None):
    url = path if path.startswith('http') else API + path
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={'Authorization': f'Bearer {token()}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors='replace')
        try:
            detail = '; '.join(f"{e.get('title')}: {e.get('detail')}" for e in json.loads(detail).get('errors', []))
        except Exception:
            pass
        sys.exit(f'{method} {url.replace(API, "")} failed ({error.code}): {detail}')


def every(path):
    """All pages of a list."""
    out, page = [], api('GET', path)
    while True:
        out += page.get('data', [])
        following = page.get('links', {}).get('next')
        if not following:
            return out
        page = api('GET', following)


def project_version():
    text = open(os.path.join(ROOT, 'project.yml')).read()
    return re.search(r'MARKETING_VERSION:\s*"?([0-9.]+)"?', text).group(1)


def copy_fields(version):
    text = open(os.path.join(ROOT, 'docs', 'app-store-listing.md')).read()
    heads = [(m.start(), m.end(), m.group(1)) for m in re.finditer(r'^## (.*)$', text, re.M)]
    def section(starts_with):
        for i, (start, end, title) in enumerate(heads):
            if title.startswith(starts_with):
                stop = heads[i + 1][0] if i + 1 < len(heads) else len(text)
                return text[end:stop].strip()
        sys.exit(f'docs/app-store-listing.md has no section "{starts_with}"')
    fields = {
        'promotionalText': section('Promotional text'),
        'keywords': section('Keywords'),
        'description': section('Description'),
        'whatsNew': section(f"What's New in {version} "),
    }
    for name, value in fields.items():
        if len(value) > LIMITS[name]:
            sys.exit(f'{name} is {len(value)} characters, over the limit of {LIMITS[name]}')
    return fields


def app_id():
    found = api('GET', f'/v1/apps?filter[bundleId]={BUNDLE}&fields[apps]=name,bundleId')['data']
    if not found:
        sys.exit(f'This key sees no app with the bundle id {BUNDLE}')
    return found[0]['id']


def versions(app):
    return every(f'/v1/apps/{app}/appStoreVersions?filter[platform]=IOS&limit=20&fields[appStoreVersions]=versionString,appStoreState,appVersionState,createdDate')


def state(version):
    a = version['attributes']
    return a.get('appVersionState') or a.get('appStoreState')


def editable_version(app, wanted, make):
    for v in versions(app):
        if v['attributes']['versionString'] == wanted:
            return v
    if not make:
        return None
    print(f'No {wanted} in App Store Connect yet: making it')
    body = {'data': {'type': 'appStoreVersions', 'attributes': {'platform': 'IOS', 'versionString': wanted},
                     'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}}
    return api('POST', '/v1/appStoreVersions', body)['data']


def localization(version):
    for loc in every(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations"):
        if loc['attributes']['locale'] == LOCALE:
            return loc
    sys.exit(f'The version has no {LOCALE} localization')


def push_copy(loc, fields, dry):
    now = loc['attributes']
    changed = {k: v for k, v in fields.items() if (now.get(k) or '') != v}
    for name in fields:
        print(f"  {name}: {len(fields[name])} of {LIMITS[name]} characters, {'changes' if name in changed else 'already there'}")
    if changed and not dry:
        api('PATCH', f"/v1/appStoreVersionLocalizations/{loc['id']}",
            {'data': {'type': 'appStoreVersionLocalizations', 'id': loc['id'], 'attributes': changed}})
        print('  sent')


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(26)
    return int.from_bytes(head[16:20], 'big'), int.from_bytes(head[20:24], 'big'), head[25]


def pictures(folder, names):
    """The set's files in upload order, each checked for what App Store Connect refuses."""
    paths = [os.path.join(ROOT, 'design', 'screenshots', folder, f'{n}.png') for n in names]
    sizes = set()
    for p in paths:
        if not os.path.exists(p):
            sys.exit(f'Missing {os.path.relpath(p, ROOT)}')
        width, height, colour = png_size(p)
        sizes.add((width, height))
        if colour in (4, 6):
            sys.exit(f'{os.path.relpath(p, ROOT)} has an alpha channel, which App Store Connect refuses')
    if len(sizes) != 1:
        sys.exit(f'{folder} holds pictures of different sizes: {sorted(sizes)}')
    if len(paths) > 10:
        sys.exit(f'{folder} lists {len(paths)} pictures; a set takes ten')
    return paths, sizes.pop()


def send_screenshot(set_id, path):
    data = open(path, 'rb').read()
    made = api('POST', '/v1/appScreenshots', {'data': {'type': 'appScreenshots', 'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data)},
               'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})['data']
    for part in made['attributes']['uploadOperations']:
        chunk = data[part['offset']: part['offset'] + part['length']]
        request = urllib.request.Request(part['url'], data=chunk, method=part['method'],
                                         headers={h['name']: h['value'] for h in part['requestHeaders']})
        urllib.request.urlopen(request, timeout=300).read()
    api('PATCH', f"/v1/appScreenshots/{made['id']}", {'data': {'type': 'appScreenshots', 'id': made['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    return made['id']


def push_screenshots(loc, dry):
    """Makes each set in App Store Connect the one in the repository. A picture that is there
    already, in its place (told by its checksum), is left alone: a new version starts with the
    last one's pictures, and usually only a few have changed."""
    sets = {s['attributes']['screenshotDisplayType']: s for s in every(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")}
    for folder, kind, names in SETS:
        paths, size = pictures(folder, names)
        sums = [hashlib.md5(open(p, 'rb').read()).hexdigest() for p in paths]
        current = sets.get(kind)
        held = every(f"/v1/appScreenshotSets/{current['id']}/appScreenshots") if current else []
        there = [h['attributes'].get('sourceFileChecksum') for h in held]
        # In step with the repository: the same number of pictures, so each has its place.
        in_step = len(held) == len(paths)
        to_send = [i for i in range(len(paths)) if not in_step or there[i] != sums[i]]
        what = 'already there' if not to_send else f"{len(to_send)} to send ({', '.join(os.path.basename(paths[i]) for i in to_send)})"
        print(f'  {folder}: {len(paths)} pictures of {size[0]}×{size[1]} as {kind}, {what}')
        if dry or not to_send:
            continue
        if current is None:
            current = api('POST', '/v1/appScreenshotSets', {'data': {'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': kind},
                          'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': loc['id']}}}}})['data']
        ids = [h['id'] for h in held] if in_step else [None] * len(paths)
        for old in (held if not in_step else [held[i] for i in to_send]):
            api('DELETE', f"/v1/appScreenshots/{old['id']}")
        for i in to_send:
            ids[i] = send_screenshot(current['id'], paths[i])
            print(f'    {os.path.basename(paths[i])}')
        api('PATCH', f"/v1/appScreenshotSets/{current['id']}/relationships/appScreenshots",
            {'data': [{'type': 'appScreenshots', 'id': i} for i in ids]})


PLACEHOLDER = '<<REVIEW KEY>>'
KEY_IN_NOTES = re.compile(r'API key:?\s*`?([^\s`,]+)')


def review_detail(version):
    return api('GET', f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get('data')


def review_key(app):
    given = os.environ.get('ASC_REVIEW_KEY')
    path = os.path.join(ROOT, 'tmp', 'asc.env')
    if not given and os.path.exists(path):
        for line in open(path):
            if line.replace('export', '').strip().startswith('ASC_REVIEW_KEY='):
                given = line.split('=', 1)[1].strip().strip('"\'')
    if given:
        return given, 'the one given'
    for v in versions(app):
        found = KEY_IN_NOTES.search(((review_detail(v) or {}).get('attributes') or {}).get('notes') or '')
        if found and not found.group(1).startswith('<<'):
            return found.group(1), f"the one in {v['attributes']['versionString']}'s notes"
    sys.exit('No test key: set ASC_REVIEW_KEY, or put one into the notes in App Store Connect once.')


def push_notes(app, version, dry):
    text = open(os.path.join(ROOT, 'docs', 'app-review-notes.md')).read()
    start = text.index('```text\n') + len('```text\n')
    notes = text[start:text.index('\n```', start)]
    if PLACEHOLDER not in notes:
        sys.exit(f'docs/app-review-notes.md has no {PLACEHOLDER} for the key to go in')
    key, where = review_key(app)
    notes = notes.replace(PLACEHOLDER, key)
    if len(notes) > 4000:
        sys.exit(f'The review notes are {len(notes)} characters with the key in, over the limit of 4000')
    detail = review_detail(version)
    if detail is None:
        sys.exit('This version has no App Review information yet: open its page in App Store Connect once, so the contact details are there.')
    same = (detail['attributes'].get('notes') or '') == notes
    print(f"  review notes: {len(notes)} of 4000 characters, test key: {where}, {'already there' if same else 'changes'}")
    if not same and not dry:
        api('PATCH', f"/v1/appStoreReviewDetails/{detail['id']}",
            {'data': {'type': 'appStoreReviewDetails', 'id': detail['id'], 'attributes': {'notes': notes}}})
        print('  sent')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    dry = '--dry-run' in sys.argv
    what = args[0] if args else ''
    if what not in ('check', 'status', 'copy', 'screenshots', 'notes', 'all'):
        sys.exit(__doc__)
    wanted = project_version()
    fields = copy_fields(wanted)
    if what == 'check':
        print(f'Version {wanted}')
        for name, value in fields.items():
            print(f'  {name}: {len(value)} of {LIMITS[name]} characters')
        for folder, kind, names in SETS:
            paths, size = pictures(folder, names)
            print(f'  {folder}: {len(paths)} pictures of {size[0]}×{size[1]} as {kind}')
        return
    app = app_id()
    if what == 'status':
        for v in versions(app)[:6]:
            print(f"  {v['attributes']['versionString']}: {state(v)}")
        version = editable_version(app, wanted, make=False)
        if version is None:
            print(f'No {wanted} yet; a push would make it.')
            return
        loc = localization(version)
        push_copy(loc, fields, dry=True)
        push_screenshots(loc, dry=True)
        push_notes(app, version, dry=True)
        return
    version = editable_version(app, wanted, make=not dry)
    if version is None:
        print(f'No {wanted} in App Store Connect yet; without --dry-run it would be made.')
        return
    print(f"Version {wanted}: {state(version)}")
    loc = localization(version)
    if what in ('copy', 'all'):
        push_copy(loc, fields, dry)
    if what in ('screenshots', 'all'):
        push_screenshots(loc, dry)
    if what == 'notes':
        push_notes(app, version, dry)


if __name__ == '__main__':
    main()
