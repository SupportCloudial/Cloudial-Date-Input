const lwcConfig = require("@salesforce/eslint-config-lwc");

module.exports = [
  ...lwcConfig.configs.recommended,
  ...lwcConfig.configs.i18n,
  {
    ignores: ["coverage/**", "node_modules/**", "test-support/**"]
  }
];
