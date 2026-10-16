"""Exercise anonymous local ADI provisioning; no Apple ID or password is used."""
import base64
import ctypes as c
import hashlib
from pathlib import Path
import plistlib
import re
import ssl
import sys
import urllib.request
import uuid


def checked(status):
    if status != 0:
        raise RuntimeError(f'Native ADI operation failed: {status}')


def run(dll, libraries, directory):
    runtime = c.CDLL(dll)
    runtime.xadi_LoadChecked.argtypes = [c.c_char_p]
    runtime.xadi_SetAndroidID.argtypes = [c.c_char_p, c.c_uint32]
    runtime.xadi_SetProvisioningPath.argtypes = [c.c_char_p]
    runtime.xadi_ProvisioningStart.argtypes = [c.c_uint64, c.c_void_p, c.c_uint32,
                                             c.POINTER(c.c_void_p), c.POINTER(c.c_uint32), c.POINTER(c.c_uint32)]
    runtime.xadi_ProvisioningEnd.argtypes = [c.c_uint32, c.c_void_p, c.c_uint32, c.c_void_p, c.c_uint32]
    runtime.xadi_GetLoginCode.argtypes = [c.c_uint64]
    runtime.xadi_OTPRequest.argtypes = [c.c_uint64, c.POINTER(c.c_void_p), c.POINTER(c.c_uint32),
                                      c.POINTER(c.c_void_p), c.POINTER(c.c_uint32)]
    runtime.xadi_Dispose.argtypes = [c.c_void_p]
    identifier = str(uuid.uuid4()).upper()
    checked(runtime.xadi_LoadChecked(libraries.encode()))
    checked(runtime.xadi_SetAndroidID(identifier.replace('-', '')[:16].lower().encode(), 16))
    checked(runtime.xadi_SetProvisioningPath(directory.encode()))
    headers = {
        'X-MMe-Client-Info': '<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKitWin/1 (com.apple.iCloud/7.21)>',
        'X-Mme-Device-Id': identifier,
        'X-Apple-I-MD-LU': hashlib.sha256(identifier.encode()).hexdigest().upper(),
        'Accept-Language': 'en_US', 'X-MMe-Country': 'US',
        'User-Agent': 'AuthKit/1 (Macintosh; OS X 27.0) (com.apple.dt.Xcode/26.5)',
        'Content-Type': 'text/x-xml-plist',
    }

    # Apple's ADI endpoints use the same Apple roots already trusted by xtool's
    # Linux client. Extend this probe's context without changing Windows trust.
    source = Path(__file__).resolve().parents[2] / 'Sources/XKit/HTTPClientProtocol/AsyncHTTPClient+HTTP.swift'
    roots = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                       source.read_text(), re.DOTALL)
    assert len(roots) == 3
    context = ssl.create_default_context()
    context.load_verify_locations(cadata='\n'.join(roots))

    def fetch(url, body=None):
        request = urllib.request.Request(url, data=body, headers=headers)
        with urllib.request.urlopen(request, timeout=30, context=context) as response:
            return plistlib.loads(response.read())

    def post(url, request):
        response = fetch(url, plistlib.dumps({'Header': {}, 'Request': request}))['Response']
        status = response.get('Status', {})
        if str(status.get('ec', 0)) != '0':
            raise RuntimeError(f'Apple ADI service returned status {status.get("ec")}')
        return response

    endpoints = fetch('https://gsa.apple.com/grandslam/GsService2/lookup')['urls']
    start = post(endpoints['midStartProvisioning'], {})
    spim = c.create_string_buffer(base64.b64decode(start['spim']))
    cpim, cpim_size, session = c.c_void_p(), c.c_uint32(), c.c_uint32()
    dsid = c.c_uint64(-2).value
    checked(runtime.xadi_ProvisioningStart(dsid, spim, len(spim.raw) - 1,
                                          c.byref(cpim), c.byref(cpim_size), c.byref(session)))
    try:
        client = base64.b64encode(c.string_at(cpim, cpim_size.value)).decode()
    finally:
        checked(runtime.xadi_Dispose(cpim))
    end = post(endpoints['midFinishProvisioning'], {'cpim': client})
    ptm, key = [c.create_string_buffer(base64.b64decode(end[name])) for name in ['ptm', 'tk']]
    checked(runtime.xadi_ProvisioningEnd(session.value, ptm, len(ptm.raw) - 1, key, len(key.raw) - 1))
    checked(runtime.xadi_GetLoginCode(dsid))
    machine, machine_size, otp, otp_size = c.c_void_p(), c.c_uint32(), c.c_void_p(), c.c_uint32()
    checked(runtime.xadi_OTPRequest(dsid, c.byref(machine), c.byref(machine_size), c.byref(otp), c.byref(otp_size)))
    try:
        assert machine_size.value > 0 and otp_size.value > 0
        assert (Path(directory) / 'adi.pb').is_file()
    finally:
        checked(runtime.xadi_Dispose(machine))
        checked(runtime.xadi_Dispose(otp))
    print('Native ADI anonymous provisioning and OTP generation passed')


if __name__ == '__main__':
    run(*sys.argv[1:])
