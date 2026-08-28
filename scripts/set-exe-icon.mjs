import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const [exePath, iconPath, modulesDir, version = "1.0.0"] = process.argv.slice(2);
if (!exePath || !iconPath || !modulesDir) {
  console.error("usage: node scripts/set-exe-icon.mjs <exe> <ico> <node_modules-dir> [version]");
  process.exit(1);
}

const peLibraryPath = path.join(modulesDir, "pe-library", "dist", "index.js");
const reseditPath = path.join(modulesDir, "resedit", "dist", "index.js");

const { NtExecutable, NtExecutableResource } = await import(pathToFileURL(peLibraryPath).href);
const ResEdit = await import(pathToFileURL(reseditPath).href);

const exe = NtExecutable.from(fs.readFileSync(exePath), { ignoreCert: true });
const resource = NtExecutableResource.from(exe);
const iconGroups = ResEdit.Resource.IconGroupEntry.fromEntries(resource.entries);
const iconGroupId = iconGroups.length > 0 ? iconGroups[0].id : 101;
const iconFile = ResEdit.Data.IconFile.from(fs.readFileSync(iconPath));

if (iconFile.icons.length === 0) {
  throw new Error(`icon file has no icons: ${iconPath}`);
}

ResEdit.Resource.IconGroupEntry.replaceIconsForResource(
  resource.entries,
  iconGroupId,
  1033,
  iconFile.icons.map((item) => item.data)
);

const versionInfos = ResEdit.Resource.VersionInfo.fromEntries(resource.entries);
if (versionInfos.length > 0) {
  versionInfos[0].setFileVersion(version, 1033);
  versionInfos[0].setProductVersion(version, 1033);
  versionInfos[0].setStringValues(
    { lang: 1033, codepage: 1200 },
    {
      FileDescription: "Reasoning Proxy",
      FileVersion: version,
      InternalName: "ReasoningProxy",
      OriginalFilename: path.basename(exePath),
      ProductName: "Reasoning Proxy",
      ProductVersion: version,
    }
  );
  versionInfos[0].outputToResourceEntries(resource.entries);
}

resource.outputResource(exe);
fs.writeFileSync(exePath, Buffer.from(exe.generate()));
console.log(`[icon] updated ${exePath} from ${iconPath}`);
