const os = require('os');

module.exports = function getServedBy() {
  return {
    platform: process.env.PLATFORM || 'aws',
    version: process.env.APP_VERSION || '1.0.0',
    instance: os.hostname(),
    commit: process.env.GIT_COMMIT || 'local',
    rollback_active: process.env.ROLLBACK_ACTIVE === 'true'
  };
};
