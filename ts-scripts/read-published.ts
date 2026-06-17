/**
 * Print one field from a package's committed Published.toml [published.<env>].
 * Used by mvr.sh to read package ids/upgrade-caps without reparsing TOML in bash.
 *
 * Usage: tsx ts-scripts/read-published.ts <pkg> <env> <field>
 *   field: original-id | published-at | upgrade-capability | version | chain-id
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parse as parseToml } from "@iarna/toml";

function main(): void {
    const [pkg, env, field] = process.argv.slice(2);
    if (!pkg || !env || !field) {
        console.error("Usage: tsx ts-scripts/read-published.ts <pkg> <env> <field>");
        process.exit(1);
    }
    const path = join("contracts", pkg, "Published.toml");
    const toml = parseToml(readFileSync(path, "utf8")) as {
        published?: Record<string, Record<string, unknown>>;
    };
    const block = toml.published?.[env];
    if (!block) throw new Error(`${path}: no [published.${env}]`);
    const v = block[field];
    if (v === undefined || v === null)
        throw new Error(`${path} [published.${env}]: missing ${field}`);
    process.stdout.write(String(v));
}

main();
