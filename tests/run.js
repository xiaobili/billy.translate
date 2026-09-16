// Loads the plugin's QML-flavoured .js files into a vm context and asserts
// against them. No dependencies: node's own test runner would need the files
// to be ES modules, and they are not.
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const ROOT = path.join(__dirname, "..")

// QML `.js` imports expose top-level declarations as properties of a module
// object; a vm context gives the same shape for free.
function load(name) {
  const file = path.join(ROOT, name)
  const context = vm.createContext({})
  vm.runInContext(fs.readFileSync(file, "utf8"), context, { filename: file })
  return context
}

let checks = 0
let failures = 0

function check(what, actual, expected) {
  checks++
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log("ok   " + what)
  } else {
    failures++
    console.log("FAIL " + what + "\n       expected " + e + "\n       actual   " + a)
  }
}

function report() {
  console.log("\n" + (checks - failures) + "/" + checks + " passed")
  process.exit(failures === 0 ? 0 : 1)
}

module.exports = { load, check, report }
