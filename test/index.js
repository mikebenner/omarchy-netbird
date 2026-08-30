// Node 26's test runner resolves a directory argument as a CommonJS module
// rather than globbing it, so `node --test test/` lands here. Requiring each
// suite keeps that form working alongside `node --test test/model.test.js`.
require("./model.test.js")
