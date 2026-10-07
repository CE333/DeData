// Leak monitor: scan a suspicious file for the canaries of a request, then print the report command.
//   node script/leak-scan.js <requestId> <path-to-suspicious-file>
const fs = require("fs");
const [id, file] = process.argv.slice(2);
const c = JSON.parse(fs.readFileSync(`out/canaries-${id}.json`, "utf8"));
const text = fs.readFileSync(file, "utf8").toLowerCase();
const hit = c.canaries.find((x) => text.includes(x.canaryHash.toLowerCase()));
console.log(hit
  ? `LEAK FOUND for request ${id}. Report it:\nnode --env-file=.env script/dedata.js report-leak ${id} ${hit.canaryHash} '${JSON.stringify(hit.proof)}'`
  : `No canary of request ${id} found in ${file}.`);
