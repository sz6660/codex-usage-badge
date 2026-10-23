'use strict';
// Recover only an activation added to a container which is then destroyed.
// No process is ever closed. Every candidate is consumed before launch.
class LostLaunchRecovery {
  constructor({launch,record=()=>{},now=Date.now}) {
    this.launch=launch;this.record=record;this.now=now;this.containers=new Map();
    this.candidate=null;this.busy=false;this.stopped=false;this.ignoreUntil=0;
  }
  async tick({events,portReady,mainPids,observedAt=this.now()}) {
    if(this.stopped||this.busy)return;
    this.busy=true;
    try {
      if(portReady)this.candidate=null;
      for(const event of events){
        const key=event.container?.replace(/[{}]/g,'').toLowerCase();
        if(!key)continue;
        if(event.id===210){this.containers.set(key,{pid:null});continue;}
        if(event.id===211){
          const container=this.containers.get(key);
          if(!container){this.containers.set(key,{pid:event.pid});continue;}
          if(container.pid==null){container.pid=event.pid;continue;}
          if(event.pid===container.pid)continue;
          // A healthy existing window's normal second-instance activation must
          // never be replayed after the user subsequently closes that window.
          if(container.wasReady&&event.fresh&&event.portWasUnavailable===true&&!portReady&&
             event.time<=observedAt&&observedAt-event.time<=5000&&observedAt>=this.ignoreUntil){
            this.candidate={container:key,pid:event.pid,oldPid:container.pid,
              recordId:event.recordId,requestedAt:event.time,destroyedAt:null,emptySince:null};
            this.record('activation-during-exit',{...this.candidate});
          }
          continue;
        }
        if(event.id===217){
          this.containers.delete(key);
          if(this.candidate?.container===key)this.candidate.destroyedAt=event.time;
        }
      }
      if(portReady){
        for(const container of this.containers.values())if(mainPids.includes(container.pid))container.wasReady=true;
      }
      const pending=this.candidate;
      if(!pending)return;
      if(observedAt-pending.requestedAt>15000){this.record('activation-recovery-expired',{recordId:pending.recordId});this.candidate=null;return;}
      if(portReady){this.candidate=null;return;}
      if(mainPids.length){pending.emptySince=null;return;}
      if(pending.destroyedAt==null)return;
      pending.emptySince??=observedAt;
      if(observedAt-pending.emptySince<2000)return;
      this.candidate=null;this.ignoreUntil=observedAt+30000;
      // The native adapter checks again immediately before invoking the OS entry.
      const result=await this.launch(pending);
      this.record(result?.launched?'lost-activation-recovered':'lost-activation-cancelled',{
        recordId:pending.recordId,reason:result?.reason??null});
    } finally {this.busy=false;}
  }
  stop(){this.stopped=true;this.candidate=null;}
}
module.exports={LostLaunchRecovery};
