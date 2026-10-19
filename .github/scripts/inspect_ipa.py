#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inspect_ipa.py — IPA 结构 / Info.plist / Mach-O / 代码签名 校验工具

用法:
    inspect_ipa.py <file.ipa> [--json] [-v]

校验内容:
  1. IPA 压缩包结构 (Payload/*.app、禁止 __MACOSX/.DS_Store、iTunesMetadata 等)
  2. Info.plist 关键字段 (Bundle ID / Version / MinimumOSVersion / 可执行文件)
  3. 主可执行文件 Mach-O 解析 (架构 / 平台 / 最低系统版本 / 签名 / FairPlay 加密)
  4. _CodeSignature/CodeResources 一致性
  5. embedded.mobileprovision 解析 (通过 openssl smime 提取 Team ID / 过期时间 / Entitlements)
  6. ldid 假签名解析 (SuperBlob 中提取 Entitlements)

退出码: 0 = 通过(可有警告), 1 = 存在错误
"""
import sys, os, io, json, zipfile, plistlib, struct, subprocess, shutil, re

# ---------------- Mach-O 常量 ----------------
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPES = {0x0000000C: 'arm', 0x0100000C: 'arm64', 0x0100000C | 0: 'arm64',
             0x00000007: 'x86', 0x01000007: 'x86_64', 0x0200000C: 'arm64_32'}
FTYPES = {1: 'MH_OBJECT', 2: 'MH_EXECUTABLE', 6: 'MH_DYLIB', 8: 'MH_BUNDLE',
          9: 'MH_DYLIB_STUB', 10: 'MH_DSYM', 11: 'MH_KEXT_BUNDLE', 12: 'MH_FILESET'}
PLATFORMS = {1: 'macOS', 2: 'iOS', 3: 'tvOS', 4: 'watchOS', 5: 'bridgeOS',
             6: 'macCatalyst', 7: 'iOS-Simulator', 8: 'tvOS-Simulator',
             9: 'watchOS-Simulator', 10: 'DriverKit'}
LC_NAMES = {
    0x1: 'LC_SEGMENT', 0x2: 'LC_SYMTAB', 0xb: 'LC_DYSYMTAB', 0xc: 'LC_LOAD_DYLIB',
    0xd: 'LC_ID_DYLIB', 0xe: 'LC_LOAD_DYLINKER', 0x19: 'LC_SEGMENT_64', 0x1b: 'LC_UUID',
    0x1c: 'LC_RPATH', 0x1d: 'LC_CODE_SIGNATURE', 0x21: 'LC_ENCRYPTION_INFO',
    0x24: 'LC_VERSION_MIN_MACOSX', 0x25: 'LC_VERSION_MIN_IPHONEOS', 0x26: 'LC_FUNCTION_STARTS',
    0x29: 'LC_DATA_IN_CODE', 0x2a: 'LC_SOURCE_VERSION', 0x2c: 'LC_ENCRYPTION_INFO_64',
    0x32: 'LC_BUILD_VERSION', 0x80000018: 'LC_LOAD_WEAK_DYLIB', 0x8000001f: 'LC_REEXPORT_DYLIB',
    0x80000020: 'LC_LAZY_LOAD_DYLIB', 0x80000022: 'LC_DYLD_INFO_ONLY',
    0x80000023: 'LC_LOAD_UPWARD_DYLIB', 0x80000028: 'LC_MAIN',
    0x80000033: 'LC_DYLD_EXPORTS_TRIE', 0x80000034: 'LC_DYLD_CHAINED_FIXUPS',
}
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSMAGIC_EMBEDDED_DER_ENTITLEMENTS = 0xFADE7172
CS_HASHTYPES = {1: 'SHA-1', 2: 'SHA-256', 3: 'SHA-256(截断)', 4: 'SHA-384'}

class Report:
    def __init__(self):
        self.errors, self.warns, self.infos = [], [], []
    def error(self, m): self.errors.append(m)
    def warn(self, m): self.warns.append(m)
    def info(self, m): self.infos.append(m)
    def ok(self, m): self.infos.append(m)

def be32(b, o=0): return struct.unpack('>I', b[o:o+4])[0]
def le32(b, o=0): return struct.unpack('<I', b[o:o+4])[0]

def parse_macho(data, path, R):
    """解析 Mach-O 头部与 load commands, 返回 (info dict, 主二进制大小)"""
    if len(data) < 32:
        R.error(f"{path}: 文件过小, 不是有效 Mach-O")
        return None
    magic = le32(data, 0)   # Mach-O magic 按小端读取: cf fa ed fe => 0xFEEDFACF
    if magic == MH_MAGIC_64:
        cputype, cpusub, ftype, ncmds, sizeofcmds, flags = struct.unpack('<6I', data[4:28])
        is64 = True
    elif magic == 0xFEEDFACE:
        R.warn(f"{path}: 32-bit Mach-O (armv7), iOS 11+ 已不支持")
        return None
    else:
        R.error(f"{path}: 不是 Mach-O 文件 (magic={hex(magic)}), 可能是脚本/文本/ELF")
        return None
    info = {'cputype': CPU_TYPES.get(cputype, hex(cputype)), 'filetype': FTYPES.get(ftype, hex(ftype)),
            'flags': flags, 'load_commands': [], 'dylibs': [], 'rpaths': [],
            'build_version': None, 'version_min_ios': None, 'has_codesign': False,
            'code_signature': None, 'encryption': None, 'entry': None, 'dylinker': None}
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(data): break
        cmd, cmdsize = struct.unpack('<II', data[off:off+8])
        name = LC_NAMES.get(cmd, hex(cmd))
        info['load_commands'].append(name)
        if cmd == 0x32:  # LC_BUILD_VERSION
            plat, minos, sdk, ntools = struct.unpack('<4I', data[off+8:off+24])
            info['build_version'] = {'platform': PLATFORMS.get(plat, str(plat)),
                                     'minos': ver_str(minos), 'sdk': ver_str(sdk)}
        elif cmd == 0x25:  # LC_VERSION_MIN_IPHONEOS
            v = le32(data, off+8)
            info['version_min_ios'] = ver_str(v)
        elif cmd == 0x24:
            v = le32(data, off+8)
            info['version_min_ios'] = f"macOS {ver_str(v)} (LC_VERSION_MIN_MACOSX)"
        elif cmd in (0xc, 0x80000018, 0x8000001f, 0x80000020, 0x80000023):  # dylib loads
            lc_off = struct.unpack('<I', data[off+8:off+12])[0]
            nm = data[off+lc_off:off+cmdsize].split(b'\0')[0].decode('utf-8', 'replace')
            info['dylibs'].append(nm)
        elif cmd == 0x1c:  # LC_RPATH
            lc_off = struct.unpack('<I', data[off+8:off+12])[0]
            info['rpaths'].append(data[off+lc_off:off+cmdsize].split(b'\0')[0].decode('utf-8', 'replace'))
        elif cmd == 0xe:  # LC_LOAD_DYLINKER
            lc_off = struct.unpack('<I', data[off+8:off+12])[0]
            info['dylinker'] = data[off+lc_off:off+cmdsize].split(b'\0')[0].decode('utf-8', 'replace')
        elif cmd == 0x1d:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack('<II', data[off+8:off+16])
            info['has_codesign'] = True
            info['code_signature'] = {'dataoff': dataoff, 'datasize': datasize}
        elif cmd == 0x2c:  # LC_ENCRYPTION_INFO_64
            cryptoff, cryptsize, cryptid = struct.unpack('<III', data[off+8:off+20])
            if cryptid != 0:
                info['encryption'] = {'cryptid': cryptid, 'size': cryptsize}
        elif cmd == 0x80000028:  # LC_MAIN
            entryoff, stacksize = struct.unpack('<QQ', data[off+8:off+24])
            info['entry'] = entryoff
        off += cmdsize
    # 解析代码签名 SuperBlob
    if info['has_codesign'] and info['code_signature']:
        cs = info['code_signature']
        blob = data[cs['dataoff']:cs['dataoff'] + cs['datasize']]
        if be32(blob, 0) == CSMAGIC_EMBEDDED_SIGNATURE:
            cs['valid_superblob'] = True
            count = be32(blob, 8)
            for i in range(count):
                t, o = struct.unpack('>II', blob[12 + 8*i:20 + 8*i])
                if o + 8 > len(blob): continue
                bmagic, blen = be32(blob, o), be32(blob, o+4)
                if bmagic == CSMAGIC_EMBEDDED_ENTITLEMENTS and blen > 8:
                    ent = blob[o+8:o+blen]
                    try:
                        cs['entitlements'] = plistlib.loads(ent)
                    except Exception:
                        cs['entitlements_raw'] = ent[:200].decode('utf-8', 'replace')
                elif bmagic == CSMAGIC_EMBEDDED_DER_ENTITLEMENTS:
                    cs['der_entitlements_len'] = blen - 8
                elif bmagic == CSMAGIC_CODEDIRECTORY and blen >= 42:
                    cd = {}
                    cd['version'] = be32(blob, o+8)     # 8
                    cd['flags'] = be32(blob, o+12)      # 12
                    cd['hashType'] = CS_HASHTYPES.get(blob[o+36], blob[o+36])   # 36
                    cd['platform'] = blob[o+37]         # 37
                    ident_off = be32(blob, o+20)        # 20: identOffset
                    cd['identifier'] = blob[o+ident_off:o+blen].split(b'\0')[0].decode('utf-8', 'replace')
                    team_off = be32(blob, o+48) if cd['version'] >= 0x20200 else 0  # 48: teamOffset
                    if team_off and o+team_off < len(blob):
                        cd['teamId'] = blob[o+team_off:o+blen].split(b'\0')[0].decode('utf-8', 'replace')
                    cs['code_directory'] = cd
        else:
            cs['valid_superblob'] = False
            R.warn(f"{path}: LC_CODE_SIGNATURE 存在但数据不是有效 SuperBlob (可能被 strip)")
    return info

def ver_str(v):
    major = (v >> 16) & 0xFFFF; minor = (v >> 8) & 0xFF; patch = v & 0xFF
    return f"{major}.{minor}.{patch}"

def parse_mobileprovision(data, R):
    """用 openssl smime 提取 embedded.mobileprovision 内容"""
    if not shutil.which('openssl'):
        R.info("embedded.mobileprovision: 存在 (未解析, 缺 openssl)")
        return None
    p = subprocess.run(['openssl', 'smime', '-verify', '-inform', 'DER', '-noverify', '-in', '/dev/stdin'],
                       input=data, capture_output=True)
    if p.returncode != 0:
        R.warn(f"embedded.mobileprovision: openssl 解析失败: {p.stderr.decode('utf-8','replace')[:120]}")
        return None
    try:
        pl = plistlib.loads(p.stdout)
        out = {}
        for k in ('Name', 'TeamName', 'ApplicationIdentifierPrefix', 'CreationDate', 'ExpirationDate'):
            if k in pl: out[k] = str(pl[k])
        if 'Entitlements' in pl: out['Entitlements'] = pl['Entitlements']
        # 设备列表
        if 'ProvisionedDevices' in pl:
            out['ProvisionedDevices'] = f"{len(pl['ProvisionedDevices'])} 台"
        return out
    except Exception as e:
        R.warn(f"embedded.mobileprovision: 内容不是 plist ({e})")
        return None

def check_ipa(path, verbose=False):
    R = Report()
    result = {'file': path, 'size': os.path.getsize(path)}
    if not zipfile.is_zipfile(path):
        R.error("不是有效的 ZIP/IPA 文件")
        return R, result
    zf = zipfile.ZipFile(path)
    names = zf.namelist()
    result['entries'] = len(names)

    # ---- 1. 顶层结构 ----
    tops = sorted(set(n.split('/')[0] for n in names if n.strip()))
    result['top_level'] = tops
    if 'Payload' not in tops:
        R.error(f"IPA 顶层缺少 Payload/ 目录 (实际: {tops}) — 无法被 iOS 安装器识别")
    extras = [t for t in tops if t not in ('Payload',)]
    if extras:
        R.info(f"顶层附加条目: {extras} (iTunesMetadata/iTunesArtwork 为可选)")
    for bad in ('__MACOSX',):
        if bad in tops: R.error(f"包含 {bad}/ (macOS zip 污染, 建议重新打包)")
    ds = [n for n in names if n.endswith('.DS_Store')]
    if ds: R.warn(f"包含 {len(ds)} 个 .DS_Store 文件 (macOS Finder 污染)")

    # ---- 2. Payload 下应恰好一个 .app ----
    apps = sorted(set('/'.join(n.split('/')[:2]) for n in names
                      if n.startswith('Payload/') and n.split('/')[1].endswith('.app') and n.count('/') >= 2))
    # 更稳妥: 找 *.app/Info.plist
    app_infos = [n for n in names if re.match(r'^Payload/[^/]+\.app/Info\.plist$', n)]
    result['apps'] = [m.group(1) for m in (re.match(r'^Payload/([^/]+\.app)/Info\.plist$', n) for n in app_infos)]
    if len(result['apps']) == 0:
        R.error("Payload/ 下未找到 *.app/Info.plist")
        return R, result
    if len(result['apps']) > 1:
        R.error(f"Payload/ 下有多个 .app: {result['apps']} (标准 IPA 只允许一个)")
    appdir = result['apps'][0]
    P = f"Payload/{appdir}"   # zip 内完整前缀

    # ---- 3. Info.plist ----
    try:
        info = plistlib.loads(zf.read(f"{P}/Info.plist"))
    except Exception as e:
        R.error(f"Info.plist 解析失败: {e}")
        return R, result
    result['bundle_id'] = info.get('CFBundleIdentifier', '<缺失>')
    result['bundle_version'] = info.get('CFBundleVersion', '<缺失>')
    result['short_version'] = info.get('CFBundleShortVersionString', '<缺失>')
    result['min_os'] = info.get('MinimumOSVersion', '<缺失>')
    exe = info.get('CFBundleExecutable', '<缺失>')
    result['executable'] = exe
    for k, label in (('CFBundleIdentifier', 'Bundle ID'), ('CFBundleVersion', 'Build'),
                     ('CFBundleShortVersionString', 'Version'), ('CFBundleExecutable', '可执行文件')):
        if k not in info: R.error(f"Info.plist 缺少 {label} ({k})")
    unexpanded = {k: v for k, v in info.items() if isinstance(v, str) and '$(' in v}
    if unexpanded:
        R.error(f"Info.plist 含未展开的构建变量 {list(unexpanded)[:3]} — "
                "打包的可能是未处理的 .app (应使用 Xcode 产物目录)")
    if 'MinimumOSVersion' not in info: R.warn("Info.plist 缺少 MinimumOSVersion")
    plats = info.get('CFBundleSupportedPlatforms', [])
    result['platforms'] = plats
    if plats and not any('iPhone' in p or 'iPad' in p or 'iOS' in p for p in plats):
        R.warn(f"CFBundleSupportedPlatforms={plats}, 不像 iOS App")
    if info.get('CFBundlePackageType', 'APPL') != 'APPL':
        R.warn(f"CFBundlePackageType={info.get('CFBundlePackageType')} (应为 APPL)")

    # ---- 4. 主可执行文件 Mach-O ----
    exe_path = f"{P}/{exe}"
    if exe_path not in names:
        R.error(f"可执行文件不存在: {exe_path}")
        return R, result
    data = zf.read(exe_path)
    minfo = parse_macho(data, exe_path, R)
    result['macho'] = minfo
    if minfo:
        if minfo['cputype'] == 'x86_64':
            R.error("主可执行文件是 x86_64 (模拟器构建), 无法安装到真机")
        elif minfo['cputype'] == 'arm64':
            R.ok("架构: arm64 (真机)")
        elif minfo['cputype'] == 'arm':
            R.warn("架构: arm (32位, 仅旧设备)")
        if minfo['filetype'] != 'MH_EXECUTABLE':
            R.warn(f"主二进制 filetype={minfo['filetype']} (预期 MH_EXECUTABLE)")
        bv = minfo['build_version']
        if bv:
            result['macho_platform'] = bv['platform']
            if bv['platform'] == 'iOS-Simulator':
                R.error("平台为 iOS-Simulator, 这是模拟器构建, 不能安装到真机")
            elif bv['platform'] not in ('iOS',):
                R.warn(f"平台为 {bv['platform']}, 预期 iOS")
            if info.get('MinimumOSVersion') and bv['minos']:
                if ver_tuple(bv['minos']) < ver_tuple(info['MinimumOSVersion']):
                    R.warn(f"Mach-O minOS={bv['minos']} < Info.plist MinimumOSVersion={info['MinimumOSVersion']}")
        if minfo['encryption']:
            R.warn(f"检测到 FairPlay 加密 (cryptid={minfo['encryption']['cryptid']}, "
                   f"{minfo['encryption']['size']} 字节) — App Store 二进制已加密, 重签名/安装前需脱壳")
        if not minfo['has_codesign']:
            R.warn("主可执行文件无 LC_CODE_SIGNATURE — 未签名(仅越狱/自签场景可用)")
        else:
            cs = minfo['code_signature']
            if not cs.get('valid_superblob'):
                R.warn("代码签名 SuperBlob 无效")
            else:
                cd = cs.get('code_directory')
                if cd:
                    result['sign_team'] = cd.get('teamId', '(无 Team ID)')
                    result['sign_id'] = cd.get('identifier')
                    if cd.get('teamId'):
                        result['sign_type'] = '证书签名'
                    else:
                        result['sign_type'] = 'ad-hoc / 自签 (无 Team ID, ldid 或 codesign -s -)'
                    if cd.get('platform') is not None and PLATFORMS.get(cd['platform']) not in (None, 'iOS'):
                        R.warn(f"签名平台={PLATFORMS.get(cd['platform'])}")
                if 'entitlements' in cs:
                    result['entitlements'] = cs['entitlements']
                    R.info(f"Mach-O 内嵌 Entitlements: {json.dumps(cs['entitlements'], ensure_ascii=False)}")
        if minfo['dylinker'] and minfo['dylinker'] != '/usr/lib/dyld':
            R.warn(f"LC_LOAD_DYLINKER={minfo['dylinker']} (预期 /usr/lib/dyld)")
        result['dylibs'] = minfo['dylibs']

    # ---- 5. _CodeSignature/CodeResources ----
    cr_path = f"{P}/_CodeSignature/CodeResources"
    if cr_path in names:
        try:
            cr = plistlib.loads(zf.read(cr_path))
            nfiles = len(cr.get('files', {}))
            result['coderesources_files'] = nfiles
            R.ok(f"_CodeSignature/CodeResources 存在 ({nfiles} 个文件条目)")
        except Exception as e:
            R.warn(f"CodeResources 解析失败: {e}")
    else:
        if minfo and minfo['has_codesign']:
            R.error("主二进制有签名但缺少 _CodeSignature/CodeResources (签名不一致)")
        else:
            R.warn("无 _CodeSignature/CodeResources (未签名)")

    # ---- 6. embedded.mobileprovision ----
    mp_path = f"{P}/embedded.mobileprovision"
    if mp_path in names:
        prov = parse_mobileprovision(zf.read(mp_path), R)
        result['provision'] = prov
        if prov:
            if prov.get('ExpirationDate'):
                R.info(f"provision 过期时间: {prov['ExpirationDate']}")
    else:
        R.info("无 embedded.mobileprovision (越狱/自签安装不需要; App Store 分发必须有)")

    # ---- 7. 其他常见资源 ----
    missing_icon = not any(n.startswith(f"{P}/AppIcon") for n in names)
    if missing_icon:
        R.info("未发现 AppIcon* 资源 (安装后可显示默认图标)")
    return R, result

def ver_tuple(s):
    try: return tuple(int(x) for x in s.split('.')[:3])
    except Exception: return (0,)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    verbose = '-v' in sys.argv
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    R, result = check_ipa(args[0], verbose)
    # 输出
    print("=" * 64)
    print(f"IPA 检查报告: {result['file']}  ({result.get('size', 0)/1024:.1f} KB)")
    print("=" * 64)
    print(f"[结构] 顶层: {result.get('top_level')}  App: {result.get('apps')}  条目数: {result.get('entries')}")
    print(f"[信息] Bundle ID : {result.get('bundle_id')}")
    print(f"[信息] 版本      : {result.get('short_version')} (Build {result.get('bundle_version')})")
    print(f"[信息] 最低系统  : {result.get('min_os')}")
    print(f"[信息] 可执行文件: {result.get('executable')}")
    m = result.get('macho')
    if m:
        print(f"[Mach-O] 架构={m['cputype']}  类型={m['filetype']}  "
              f"平台={m['build_version']['platform'] if m['build_version'] else result.get('macho_platform','?')}  "
              f"minOS={m['build_version']['minos'] if m['build_version'] else '?'}")
        if m.get('code_signature') and m['code_signature'].get('valid_superblob'):
            print(f"[签名] 类型={result.get('sign_type')}  Team={result.get('sign_team')}  ID={result.get('sign_id')}")
        elif m['has_codesign']:
            print("[签名] 存在 LC_CODE_SIGNATURE 但 SuperBlob 无效")
        else:
            print("[签名] 未签名")
        if m['dylibs']:
            print(f"[Mach-O] 依赖库 ({len(m['dylibs'])}): " + ", ".join(m['dylibs'][:8]) + (" ..." if len(m['dylibs']) > 8 else ""))
    if 'coderesources_files' in result:
        print(f"[签名] CodeResources: {result['coderesources_files']} 个文件")
    p = result.get('provision')
    if p:
        print(f"[Provision] Name={p.get('Name')} Team={p.get('TeamName')} ({p.get('ApplicationIdentifierPrefix')})")
        print(f"[Provision] 创建={p.get('CreationDate')} 过期={p.get('ExpirationDate')}")
        if 'Entitlements' in p:
            print(f"[Provision] Entitlements: {json.dumps(p['Entitlements'], ensure_ascii=False)[:300]}")
    print("-" * 64)
    for i in R.infos:
        if verbose or i.startswith(('检测到', 'provision', 'Mach-O 内嵌', '_CodeSignature', '架构')):
            print(f"  ℹ {i}")
    for w in R.warns:
        print(f"  ⚠ {w}")
    for e in R.errors:
        print(f"  ✗ {e}")
    if not R.errors and not R.warns:
        print("  ✓ 全部检查通过")
    print("-" * 64)
    print(f"结果: {len(R.errors)} 个错误, {len(R.warns)} 个警告")
    sys.exit(1 if R.errors else 0)

if __name__ == '__main__':
    main()
