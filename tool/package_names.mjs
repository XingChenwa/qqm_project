import {readFile, appendFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {readVersion, assetDefinitions} from './github_release_core.mjs';

export function packageNames(version, build) {
  const names = {};
  for (const asset of assetDefinitions(version, build)) {
    names[asset.platform + '_file'] = asset.name;
    names[asset.platform + '_artifact'] = asset.directory;
  }
  names.macos_zip = `qqbotmanager-macos-v${version}-build${build}-universal.zip`;
  names.linux_file = `qqbotmanager-linux-v${version}-build${build}-web-x64.tar.gz`;
  names.linux_artifact = `linux-v${version}-build${build}-web-x64`;
  names.linux_checksum = names.linux_file + '.sha256';
  return names;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const info = readVersion(await readFile('pubspec.yaml','utf8'), await readFile('lib/utils/constants.dart','utf8'));
  const names = packageNames(info.version, info.build);
  const argument = process.argv[2];
  if (argument === 'github-output') {
    if (!process.env.GITHUB_OUTPUT) throw new Error('Missing GitHub output file');
    const newline = String.fromCharCode(10);
    await appendFile(process.env.GITHUB_OUTPUT,
      Object.entries(names).map(([key, value]) => `${key}=${value}`).join(newline) + newline);
  } else if (argument === 'json') {
    console.log(JSON.stringify(names));
  } else if (Object.hasOwn(names, argument)) {
    console.log(names[argument]);
  } else {
    throw new Error('Unknown package filename key');
  }
}
