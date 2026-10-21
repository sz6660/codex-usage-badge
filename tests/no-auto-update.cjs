'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const forbid=new Proxy({},{get(){throw Error('Background updater touched filesystem');}});
async function run(file,args){
  const sandbox={module:{exports:{}},__dirname:path.dirname(path.join(root,file)),
    process:{platform:'darwin',argv:['node',file,...args]},console:{log(){}},
    fetch(){throw Error('Background updater accessed network');},
    require:id=>id==='node:fs'?forbid:require(id==='./core.cjs'?path.join(root,'updater/core.cjs'):id)};
  const code=fs.readFileSync(path.join(root,file),'utf8');
  vm.runInNewContext(code+'\nmodule.exports.testMain=main;',sandbox,{filename:file});
  await sandbox.module.exports.testMain(args);
}
(async()=>{
  await run('windows/update.cjs',[]);
  await run('updater/worker.cjs',['run']);
  await run('updater/worker.cjs',['enable']);
  if(process.platform==='win32'){
    const script=String.raw`$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($args[0],[Text.Encoding]::UTF8),[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Parser failed'};$run=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Run-Worker'},$true);if($run.Extent.Text -match 'CheckUpdate|nextUpdateCheck'){throw 'Background update scheduler remains'}`;
    const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',`& { ${script} } '${path.join(root,'windows/manage-windows.ps1').replaceAll("'","''")}'`],{encoding:'utf8',windowsHide:true});
    assert.equal(result.status,0,result.stderr);
  }
  console.log('PASS retired Windows/macOS background calls perform no file access or fetch; Windows supervisor has no update scheduler');
})().catch(error=>{console.error(error);process.exitCode=1;});
