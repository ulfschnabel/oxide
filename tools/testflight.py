"""Oxide: App Store profile, archive, upload, wait for processing, share with internal testers.

Usage: testflight.py [check|profiles|all]  (uv run --with pyjwt --with cryptography)
"""
import base64, hashlib, json, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

import jwt

# Account details live in testflight.local.json next to this script (not in git):
# {"key_id", "issuer", "key_path", "team_id", "testers": [[email, first, last]], "extra_visible_users": [user ids]}
LOCAL = json.loads((Path(__file__).resolve().parent / "testflight.local.json").read_text())
KEY_ID, ISSUER, TEAM_ID = LOCAL["key_id"], LOCAL["issuer"], LOCAL["team_id"]
KEY_PATH = Path(LOCAL["key_path"]).expanduser()
APP_BUNDLE = "com.ulfschnabel.duodesk"
BUNDLES = [APP_BUNDLE]
PROJECT = Path(__file__).resolve().parent.parent
ARCHIVE = PROJECT / "build/Oxide.xcarchive"
TESTERS = [tuple(t) for t in LOCAL["testers"]]
EXTRA_VISIBLE_USERS = LOCAL.get("extra_visible_users", [])  # DEVELOPER-role users need per-app visibility
GROUP = "Internal Testers"
BASE = "https://api.appstoreconnect.apple.com/v1"
AUTH = ["-allowProvisioningUpdates", "-authenticationKeyPath", str(KEY_PATH),
        "-authenticationKeyID", KEY_ID, "-authenticationKeyIssuerID", ISSUER]


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def token():
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      KEY_PATH.read_bytes(), algorithm="ES256", headers={"kid": KEY_ID})


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read().decode()[:500]}") from None


def wait_for(what, fn, timeout, every):
    end = time.time() + timeout
    while time.time() < end:
        result = fn()
        if result:
            return result
        time.sleep(every)
    sys.exit(f"timed out waiting for {what}")


def distribution_cert_id():
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
    sha1 = next((l.split()[1].upper() for l in out.splitlines() if '"Apple Distribution:' in l), None)
    if not sha1:
        sys.exit("no local Apple Distribution identity in keychain")
    certs = call("GET", "/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=50")["data"]
    for c in certs:
        if hashlib.sha1(base64.b64decode(c["attributes"]["certificateContent"])).hexdigest().upper() == sha1:
            return c["id"]
    sys.exit(f"local distribution cert {sha1} not found in ASC")


def ensure_profile(bundle, cert_id):
    """Create (or reuse) the '<bundle> AppStore' profile and install it."""
    bundle_id = call("GET", f"/bundleIds?filter[identifier]={bundle}")["data"][0]["id"]
    name = f"{bundle} AppStore"
    existing = [p for p in call("GET", f"/bundleIds/{bundle_id}/profiles")["data"]
                if p["attributes"]["name"] == name and p["attributes"]["profileState"] == "ACTIVE"]
    profile = existing[0] if existing else call("POST", "/profiles", {"data": {"type": "profiles",
        "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                          "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})["data"]
    attrs = profile["attributes"]
    dest = Path("~/Library/MobileDevice/Provisioning Profiles").expanduser()
    dest.mkdir(parents=True, exist_ok=True)
    (dest / f"{attrs['uuid']}.mobileprovision").write_bytes(base64.b64decode(attrs["profileContent"]))
    log(f"profile '{name}' {attrs['uuid']} installed")
    return name


def run_logged(cmd, logfile):
    with open(PROJECT / logfile, "w") as f:
        rc = subprocess.run(cmd, cwd=PROJECT, stdout=f, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        sys.exit(f"{cmd[1]} failed (rc={rc}), see {PROJECT / logfile}")


def archive():
    run_logged(["xcodegen", "generate", "-q"], "build-xcodegen.log")
    run_logged(["xcodebuild", "archive", "-project", "Oxide.xcodeproj", "-scheme", "Oxide", "-configuration", "Release",
                "-destination", "generic/platform=iOS", "-archivePath", str(ARCHIVE)], "build-archive.log")
    log("archived")


def upload(profiles):
    entries = "".join(f"<key>{b}</key><string>{n}</string>" for b, n in profiles.items())
    opts = PROJECT / "build/ExportOptions.plist"
    opts.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>{TEAM_ID}</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Apple Distribution</string>
<key>provisioningProfiles</key><dict>{entries}</dict>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
""")
    run_logged(["xcodebuild", "-exportArchive", "-archivePath", str(ARCHIVE), "-exportOptionsPlist", str(opts),
                "-exportPath", str(PROJECT / "build/export"), *AUTH], "build-upload.log")
    log("uploaded")


def build_version():
    out = subprocess.run(["plutil", "-extract", "ApplicationProperties.CFBundleVersion", "raw",
                          str(ARCHIVE / "Info.plist")], capture_output=True, text=True).stdout.strip()
    return out or "1"


def processed_build(app_id, version):
    data = call("GET", f"/builds?filter[app]={app_id}&filter[version]={version}&limit=5")["data"]
    for b in data:
        state = b["attributes"]["processingState"]
        log(f"build {b['id']} state={state}")
        if state == "VALID":
            return b["id"]
        if state in ("FAILED", "INVALID"):
            sys.exit(f"build processing {state}")
    return None


def internal_group(app_id):
    for g in call("GET", f"/apps/{app_id}/betaGroups")["data"]:
        if g["attributes"]["name"] == GROUP:
            return g["id"]
    return call("POST", "/betaGroups", {"data": {"type": "betaGroups",
        "attributes": {"name": GROUP, "isInternalGroup": True},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]["id"]


def share(app_id, build_id):
    for user in EXTRA_VISIBLE_USERS:
        try:
            call("POST", f"/users/{user}/relationships/visibleApps",
                 {"data": [{"type": "apps", "id": app_id}]})
        except RuntimeError as e:
            log(f"visibleApps: {e}")
    group_id = internal_group(app_id)
    try:
        call("POST", f"/betaGroups/{group_id}/relationships/builds",
             {"data": [{"type": "builds", "id": build_id}]})
    except RuntimeError as e:  # internal groups with access to all builds reject explicit assignment
        log(f"build assignment skipped: {e}")
    for email, first, last in TESTERS:
        try:
            call("POST", "/betaTesters", {"data": {"type": "betaTesters",
                "attributes": {"email": email, "firstName": first, "lastName": last},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}}}})
            log(f"added tester {email}")
        except RuntimeError as e:
            log(f"tester {email}: {e}")
    return group_id


def main():
    if sys.argv[1:] == ["check"]:
        apps = call("GET", f"/apps?filter[bundleId]={APP_BUNDLE}")["data"]
        ids = call("GET", f"/bundleIds?filter[identifier]={APP_BUNDLE}")["data"]
        print("app:", [a["id"] for a in apps], "bundleId:", [b["id"] for b in ids])
        return
    cert_id = distribution_cert_id()
    profiles = {b: ensure_profile(b, cert_id) for b in BUNDLES}
    if sys.argv[1:] == ["profiles"]:
        return
    app_id = call("GET", f"/apps?filter[bundleId]={APP_BUNDLE}")["data"][0]["id"]
    archive()
    upload(profiles)
    version = build_version()
    build_id = wait_for("processing", lambda: processed_build(app_id, version), timeout=5400, every=60)
    group_id = share(app_id, build_id)
    log(f"DONE app={app_id} build={build_id} ({version}) group={group_id}")


if __name__ == "__main__":
    main()
