import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

const root = fileURLToPath(new URL("../", import.meta.url));
const readJson = async (relativePath) =>
  JSON.parse(await readFile(new URL(relativePath, new URL("../", import.meta.url)), "utf8"));

const [identity, schema] = await Promise.all([
  readJson("package.identity.json"),
  readJson("schemas/package-identity.schema.json")
]);

const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
  validateFormats: false
});
const validate = ajv.compile(schema);

if (!validate(identity)) {
  console.error(`Invalid package identity at ${root}package.identity.json`);
  for (const error of validate.errors) {
    console.error(`${error.instancePath || "/"} ${error.message}`);
  }
  process.exitCode = 1;
} else {
  console.log("package.identity.json is valid.");
}
