"""构建工具的隔离合成编辑资源；仅模拟清单，不代替真实 Node 构建。"""
import json
import plistlib
import shutil


def make_editors(root, application=None):
    assets = root / 'EditorAssets'
    for name in ['build.mjs', 'package.json', 'package-lock.json', 'src/index.mjs', 'src/index.html', 'src/editor.css']:
        path = assets / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('fixture ' + name)
    return update_editors(root, application)


def update_editors(root, application=None):
    import native_sources as native
    origin = root / 'Resources/Editors'
    origin.mkdir(parents=True, exist_ok=True)
    for name in native.REQUIRED_EDITOR_RESOURCES:
        path = origin / name
        if not path.exists(): path.write_text('fixture ' + name)
    inputs = {p.relative_to(root).as_posix(): native.digest(p.read_bytes())
              for p in (root / 'EditorAssets').rglob('*') if p.is_file()}
    metadata = {'schema': 2, 'inputs': inputs,
                'dependenciesLockSHA256': inputs['EditorAssets/package-lock.json'],
                'files': {name: native.digest((origin / name).read_bytes()) for name in native.REQUIRED_EDITOR_RESOURCES}}
    (origin / 'manifest.json').write_text(json.dumps(metadata))
    if application:
        shutil.copytree(origin, application / 'Contents/Resources/FileWorkbenchEditors', dirs_exist_ok=True)
    return origin


def make_bundle(root, application):
    import verify_bundle as checker
    def file(relative, data=b'fixture', binary=False):
        path = application / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((b'\xcf\xfa\xed\xfe' if binary else b'') + data)
        if binary: path.chmod(0o755)
    def plist(prefix, name):
        file(prefix + 'Contents/Info.plist', plistlib.dumps({'CFBundleExecutable': name,
             'CFBundleIdentifier': 'local.fileworkbench.desktop', 'CFBundleVersion': '6', 'CFBundleShortVersionString': '0.1.2'}))
        file(prefix + 'Contents/MacOS/' + name, binary=True)
    plist('', 'FileDeck')
    for relative in checker.REQUIRED_FILES: file(relative)
    for relative in checker.REQUIRED_DIRECTORIES: file(relative + '/fixture.txt')
    for relative in checker.REQUIRED_BINARIES.values(): file(relative, binary=True)
    for name in checker.HELPERS: plist('Contents/Frameworks/' + name + '.app/', name)
    return make_editors(root, application)
