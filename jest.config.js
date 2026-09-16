const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  collectCoverageFrom: [
    "<rootDir>/force-app/main/default/lwc/**/*.js",
    "!<rootDir>/force-app/main/default/lwc/**/__tests__/**"
  ]
};
