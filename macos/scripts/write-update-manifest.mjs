import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const [out, version, arch] = process.argv.slice(2);
if (!/^\d+\.\d+\.\d+$/.test(version ?? "") || !["aarch64", "x86_64"].includes(arch)) {
  throw new Error("Expected output directory, stable semantic version, and supported architecture");
}
const archive = `Cloudreve_${version}_${arch}.app.tar.gz`;
const signature = readFileSync(join(out, `${archive}.sig`), "utf8").trim();
if (!signature) throw new Error("Missing update signature");
const manifest = {
  version,
  notes: "See the GitHub release notes before updating. Save your work and close Cloudreve documents before installation.",
  pub_date: new Date().toISOString(),
  platforms: {
    [`darwin-${arch}`]: {
      signature,
      url: `https://github.com/daddyboiAnderson/cloudreve-desktop/releases/download/v${version}/${archive}`,
    },
  },
};
writeFileSync(join(out, "latest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
