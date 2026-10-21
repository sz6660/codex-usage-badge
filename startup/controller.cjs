'use strict';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
class StartupController {
  constructor(adapter, {now=Date.now, sleep=delay, lastAttemptAt=0}={}) {
    Object.assign(this,{adapter,now,sleep,lastAttemptAt});
    this.baselined=false; this.seen=new Set(); this.busy=false; this.stopped=false;
  }
  stop() { this.stopped=true; }
  async tick() {
    if(this.busy||this.stopped)return;
    this.busy=true;
    this.pendingLaunch=false;
    try {
      const snapshot=await this.adapter.snapshot();
      if(!this.baselined) {
        for(const app of snapshot.apps)this.seen.add(app.key);
        this.baselined=true;
        await this.adapter.record('watching',{existingApps:snapshot.apps.length});
        return;
      }
      const fresh=snapshot.apps.filter(app=>!this.seen.has(app.key));
      if(this.seen.size>256)this.seen=new Set(snapshot.apps.map(app=>app.key));
      if(fresh.length!==1||snapshot.apps.length!==1) {
        for(const app of snapshot.apps)this.seen.add(app.key);
        return;
      }
      const app=fresh[0], age=this.now()-app.launchedAt;
      if(!app.argumentsKnown||app.plainLaunch===false||app.debugPort!==null) { this.seen.add(app.key); return; }
      // Only activity attributed to this client protects it; other apps may stay active.
      const clientIdle=app.inputIdleMs;
      const known=typeof app.inputStamp==='string'&&app.inputStamp!=='unknown'&&Number.isFinite(clientIdle);
      if((!app.finishedLaunching||!known) && age>=0 && age<=8000 && (!known||clientIdle>=age)) {
        this.pendingLaunch=true; return;
      }
      this.seen.add(app.key);
      if(age<0||age>8000||!known||clientIdle<age) {
        await this.adapter.record('skipped-client-active',{
          reason:age<0||age>8000?'launch-age':!known?'input-unavailable':'client-input',
          ageMs:Math.round(age),clientInputIdleMs:known?Math.min(Math.round(clientIdle),86400000):null,
          frontmostPid:snapshot.frontmostPid,processKey:app.key
        }); return;
      }
      // Each process identity is handled once, including our replacement below.
      // A different user launch must not be suppressed by a global cooldown.
      if(await this.adapter.portInUse()) { await this.adapter.record('port-in-use'); return; }
      if(this.stopped)return;
      // Durable receipt must succeed before any quit request. A failure/restart cannot cause a loop.
      this.lastAttemptAt=this.now();
      await this.adapter.record('attempt',{lastAttemptAt:this.lastAttemptAt,processKey:app.key});
      if(this.stopped)return;
      const quit=await this.adapter.quit(app,app.inputStamp);
      if(!quit.accepted) { await this.adapter.record('quit-refused',{
        reason:quit.reason||'unknown',errorCode:quit.errorCode??null,
        processCount:quit.processCount??null,rebootReason:quit.rebootReason??null
      }); return; }
      const deadline=this.now()+10000;
      let absent=null;
      while(!this.stopped&&this.now()<deadline) {
        await this.sleep(200);
        const current=await this.adapter.snapshot();
        if(current.apps.some(a=>a.key!==app.key)) {
          for(const a of current.apps)this.seen.add(a.key);
          await this.adapter.record('another-instance-started'); return;
        }
        if(current.apps.length===0) { absent=current; break; }
      }
      if(this.stopped)return;
      if(!absent) { await this.adapter.record('quit-timeout'); return; }
      // Once our graceful quit completed, restore the client even if other apps receive input.
      await this.sleep(250);
      const beforeLaunch=await this.adapter.snapshot();
      if(this.stopped||beforeLaunch.apps.length) {
        for(const a of beforeLaunch.apps)this.seen.add(a.key);
        await this.adapter.record('reopen-canceled'); return;
      }
      const opened=await this.adapter.launch(snapshot.inputStamp,beforeLaunch.frontmostPid);
      if(!opened.launched) { await this.adapter.record('launch-failed'); return; }
      if(opened.key)this.seen.add(opened.key);
      if(this.stopped)return;
      // Visibility must not depend on permission to take foreground focus.
      const shown=await this.adapter.show(opened,snapshot.inputStamp,snapshot.frontmostPid===app.pid?beforeLaunch.frontmostPid:-1);
      await this.adapter.record(shown.shown?'reopened':'reopened-window-pending',{
        shown:!!shown.shown,activated:!!shown.activated,reason:shown.reason||null,processKey:opened.key
      });
    } catch(error) {
      await this.adapter.record('error',{message:error.message}).catch(()=>{});
    } finally { this.busy=false; }
  }
}
module.exports={StartupController};
