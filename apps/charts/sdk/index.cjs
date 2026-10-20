// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// The same validator shipped in the clients. No renderer or browser is required.
const { validate, fence, kinds } = require("../runtime/contract.js");
module.exports = Object.freeze({ validate, chart: fence, kinds });
