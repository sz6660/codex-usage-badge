'use strict';
require('./startup-controller-cases.cjs')('../startup/controller.cjs').catch(error=>{console.error(error);process.exitCode=1;});
