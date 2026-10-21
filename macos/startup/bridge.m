#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <sys/sysctl.h>

// Read event counters/timing only, never keyboard content, window titles or screenshots.
static NSArray *eventTypes(void) { return @[@(kCGEventKeyDown), @(kCGEventLeftMouseDown), @(kCGEventRightMouseDown), @(kCGEventOtherMouseDown), @(kCGEventScrollWheel)]; }
static NSString *inputStamp(void) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *t in eventTypes()) [parts addObject:[NSString stringWithFormat:@"%llu", (unsigned long long)CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState, t.unsignedIntValue)]];
    return [parts componentsJoinedByString:@":"];
}
static double inputIdleMs(void) {
    double seconds = 1e9;
    for (NSNumber *t in eventTypes()) seconds = fmin(seconds, CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, t.unsignedIntValue));
    return isfinite(seconds) ? seconds * 1000 : 0;
}
static NSString *canonical(NSString *path) { return path.stringByStandardizingPath.stringByResolvingSymlinksInPath; }
static BOOL matches(NSRunningApplication *a, NSString *path) {
    if (!a || a.terminated || ![canonical(a.bundleURL.path) isEqualToString:canonical(path)]) return NO;
    char executable[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(a.processIdentifier, executable, sizeof(executable)) <= 0) return NO;
    return [canonical(@(executable)) isEqualToString:canonical(a.executableURL.path)];
}
static NSDictionary *argumentsState(pid_t pid) {
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid}; size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) || size > 4*1024*1024 || size < sizeof(int)) return @{@"known":@NO};
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (sysctl(mib, 3, data.mutableBytes, &size, NULL, 0)) return @{@"known":@NO};
    char *start = data.mutableBytes, *end = start + size, *p = start + sizeof(int);
    int argc = 0; memcpy(&argc, start, sizeof(argc));
    if (argc < 1 || argc > 8192) return @{@"known":@NO};
    while (p < end && *p) p++; // executable path
    while (p < end && !*p) p++;
    NSMutableArray *args = [NSMutableArray array];
    for (int i = 0; i < argc && p < end; i++) {
        size_t n = strnlen(p, end-p); if (p+n >= end) return @{@"known":@NO};
        NSString *s = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding];
        if (!s) return @{@"known":@NO};
        [args addObject:s]; p += n+1;
    }
    if (args.count != (NSUInteger)argc) return @{@"known":@NO};
    id port = NSNull.null;
    for (NSUInteger i=0; i<args.count; i++) {
        NSString *s = args[i];
        if ([s hasPrefix:@"--remote-debugging-port="]) port = [s substringFromIndex:24];
        if ([s isEqualToString:@"--remote-debugging-port"]) port = i+1<args.count ? args[i+1] : @"";
    }
    return @{@"known":@YES, @"port":port,@"plain":@(args.count==1)};
}
static NSString *identity(NSRunningApplication *a) {
    return [NSString stringWithFormat:@"%d:%.0f", a.processIdentifier, a.launchDate.timeIntervalSince1970*1000];
}
// A persistent helper associates counter changes with a stable foreground client.
// No event tap, Accessibility permission, key contents or window titles are used.
static BOOL monitoringClient=NO;
static NSMutableDictionary *clientInputs;
static NSString *previousClientKey;
static uint32_t previousCounters[5];
static BOOL countersReady=NO;
static double previousSampleAt=0;
static NSString *keyForEvent(CGEventType type,NSString *front,NSString *previous,NSString *pointer) {
    return type==kCGEventKeyDown?([front isEqualToString:previous]?front:nil):pointer;
}
static void recordClientInput(NSString *key,double now,double eventAt) {
    if(!key)return;
    NSMutableDictionary *entry=clientInputs[key];
    if(!entry) {entry=[@{@"firstSeen":@(now),@"lastInput":@0,@"sequence":@0} mutableCopy];clientInputs[key]=entry;}
    entry[@"lastInput"]=@(eventAt);entry[@"sequence"]=@([entry[@"sequence"] unsignedLongLongValue]+1);
}
static NSString *pointerClientKey(NSString *path) {
    CGEventRef event=CGEventCreate(NULL);if(!event)return nil;
    CGPoint point=CGEventGetLocation(event);CFRelease(event);
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    for(NSDictionary *window in windows) {
        if([window[(__bridge id)kCGWindowLayer] intValue]!=0)continue;
        CGRect bounds;
        if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge id)kCGWindowBounds],&bounds)||!CGRectContainsPoint(bounds,point))continue;
        NSRunningApplication *owner=[NSRunningApplication runningApplicationWithProcessIdentifier:[window[(__bridge id)kCGWindowOwnerPID] intValue]];
        return matches(owner,path)&&owner.launchDate?identity(owner):nil;
    }
    return nil;
}
static void sampleClientActivity(NSString *path) {
    if (!monitoringClient) return;
    double now=NSDate.date.timeIntervalSince1970*1000;
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    NSString *key=matches(front,path)&&front.launchDate?identity(front):nil;
    NSString *pointer=nil;BOOL pointerRead=NO;
    NSArray *types=eventTypes();
    for(NSUInteger i=0;i<types.count;i++) {
        CGEventType type=[types[i] unsignedIntValue];
        uint32_t count=CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState,type);
        double eventAt=now-CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,type)*1000;
        if(countersReady&&count!=previousCounters[i]&&eventAt>previousSampleAt) {
            if(type!=kCGEventKeyDown&&!pointerRead) {pointer=pointerClientKey(path);pointerRead=YES;}
            recordClientInput(keyForEvent(type,key,previousClientKey,pointer),now,eventAt);
        }
        previousCounters[i]=count;
    }
    previousClientKey=key;previousSampleAt=now;countersReady=YES;
    if(clientInputs.count>256) {
        NSMutableDictionary *current=key?clientInputs[key]:nil;
        [clientInputs removeAllObjects];if(current)clientInputs[key]=current;
    }
}
static NSDictionary *clientActivity(NSRunningApplication *a) {
    if (!monitoringClient) return @{@"inputStamp":@"unknown",@"inputIdleMs":@0};
    double now=NSDate.date.timeIntervalSince1970*1000;
    NSString *key=identity(a);NSMutableDictionary *entry=clientInputs[key];
    if (!entry) { entry=[@{@"firstSeen":@(now),@"lastInput":@0,@"sequence":@0} mutableCopy];clientInputs[key]=entry; }
    if(now-[entry[@"firstSeen"] doubleValue]<250) return @{@"inputStamp":@"unknown",@"inputIdleMs":@0};
    return @{@"inputStamp":[entry[@"sequence"] stringValue],@"inputIdleMs":@([entry[@"lastInput"] doubleValue]>0?now-[entry[@"lastInput"] doubleValue]:1e15)};
}
static NSDictionary *snapshot(NSString *path) {
    sampleClientActivity(path);
    NSMutableArray *apps = [NSMutableArray array];
    NSWorkspace *w = NSWorkspace.sharedWorkspace;
    for (NSRunningApplication *a in w.runningApplications) {
        if (!matches(a,path) || !a.launchDate) continue;
        NSDictionary *args = argumentsState(a.processIdentifier);
        NSDictionary *activity=clientActivity(a);
        [apps addObject:@{@"pid":@(a.processIdentifier), @"key":identity(a), @"launchedAt":@(a.launchDate.timeIntervalSince1970*1000), @"finishedLaunching":@(a.finishedLaunching), @"argumentsKnown":args[@"known"],@"plainLaunch":args[@"plain"]?:@NO, @"debugPort":args[@"port"] ?: NSNull.null,@"inputStamp":activity[@"inputStamp"],@"inputIdleMs":activity[@"inputIdleMs"]}];
    }
    return @{@"apps":apps, @"frontmostPid":@(w.frontmostApplication.processIdentifier), @"inputStamp":inputStamp(), @"inputIdleMs":@(inputIdleMs())};
}
static id requestId;
static void output(id object) {
    if(requestId) object=@{@"id":requestId,@"result":object};
    NSData *d = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!d) exit(2);
    fwrite(d.bytes,1,d.length,stdout); fputc('\n',stdout); fflush(stdout);
}
static NSDictionary *restoreDock(NSString *app, NSString *oldLauncher) {
    NSString *bundle=[NSBundle bundleWithPath:app].bundleIdentifier;
    if (!bundle) return @{@"ok":@NO};
    CFPropertyListRef value=CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    id existing=CFBridgingRelease(value);
    if (!existing) return @{@"ok":@YES,@"changed":@NO};
    if (![existing isKindOfClass:NSArray.class]) return @{@"ok":@NO};
    BOOL originalPinned=NO, changed=NO;
    for (NSDictionary *tile in existing) {
        NSString *url=tile[@"tile-data"][@"file-data"][@"_CFURLString"];
        if (url && [canonical([NSURL URLWithString:url].path) isEqualToString:app]) originalPinned=YES;
    }
    NSMutableArray *updated=[NSMutableArray array];
    for (NSDictionary *tile in existing) {
        NSDictionary *data=tile[@"tile-data"];
        NSString *url=data[@"file-data"][@"_CFURLString"];
        BOOL owned=[data[@"bundle-identifier"] isEqual:@"local.codexusagebadge.launcher"] && url && [canonical([NSURL URLWithString:url].path) isEqualToString:oldLauncher];
        if (!owned) { [updated addObject:tile]; continue; }
        changed=YES;
        if (originalPinned) continue;
        NSMutableDictionary *replacement=[tile mutableCopy], *details=[data mutableCopy];
        details[@"file-data"]=@{@"_CFURLString":[NSURL fileURLWithPath:app isDirectory:YES].absoluteString,@"_CFURLStringType":@15};
        details[@"bundle-identifier"]=bundle;
        details[@"file-label"]=[NSFileManager.defaultManager displayNameAtPath:app];
        [details removeObjectsForKeys:@[@"book",@"file-mod-date",@"parent-mod-date"]];
        replacement[@"tile-data"]=details; [updated addObject:replacement]; originalPinned=YES;
    }
    if (changed) {
        id latest=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("persistent-apps"),CFSTR("com.apple.dock")));
        if (![latest isEqual:existing]) return @{@"ok":@NO};
        CFPreferencesSetAppValue(CFSTR("persistent-apps"),(__bridge CFArrayRef)updated,CFSTR("com.apple.dock"));
        if (!CFPreferencesAppSynchronize(CFSTR("com.apple.dock"))) return @{@"ok":@NO};
    }
    return @{@"ok":@YES,@"changed":changed?@YES:@NO};
}
static int handleAction(int argc, const char *argv[]) { @autoreleasepool {
    if (argc < 3) return 2;
    NSString *action=@(argv[1]), *path=canonical(@(argv[2]));
    if ([action isEqualToString:@"restore-dock"] && argc==4) { output(restoreDock(path,canonical(@(argv[3])))); return 0; }
    if ([action isEqualToString:@"snapshot"]) { output(snapshot(path)); return 0; }
    if ([action isEqualToString:@"watch"]) {
        NSApplication *application=NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSNotificationCenter *center=NSWorkspace.sharedWorkspace.notificationCenter;
        __block NSDictionary *previous=nil;
        __block NSUInteger quietTicks=0;
        void (^emit)(BOOL)=^(BOOL force){
            NSDictionary *current=snapshot(path);
            NSDictionary *identityState=@{@"apps":current[@"apps"],@"frontmostPid":current[@"frontmostPid"]};
            if (force || ![identityState isEqual:previous] || ++quietTicks>=30) {
                previous=identityState; quietTicks=0; output(current);
            }
        };
        for (NSString *name in @[NSWorkspaceDidLaunchApplicationNotification, NSWorkspaceDidTerminateApplicationNotification, NSWorkspaceDidActivateApplicationNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                NSRunningApplication *a=note.userInfo[NSWorkspaceApplicationKey];
                if ([name isEqualToString:NSWorkspaceDidActivateApplicationNotification] || [canonical(a.bundleURL.path) isEqualToString:path]) emit(YES);
            }];
        }
        // Some builds omit workspace notifications. Check in this persistent native process;
        // only changed app state (or a 30-second heartbeat) wakes the Node controller.
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){ (void)timer; emit(NO); }];
        emit(YES);
        [application run]; return 0;
    }
    if ([action isEqualToString:@"quit"] && argc==6) {
        NSRunningApplication *a=[NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[3])];
        double age = a.launchDate ? (NSDate.date.timeIntervalSince1970-a.launchDate.timeIntervalSince1970)*1000 : INFINITY;
        NSDictionary *args = a ? argumentsState(a.processIdentifier) : @{};
        // Recheck all guards at the native action boundary. No forceTerminate, kill or app activation.
        sampleClientActivity(path);
        NSDictionary *activity=a?clientActivity(a):@{};
        BOOL safe = matches(a,path) && a.finishedLaunching && [identity(a) isEqualToString:@(argv[4])] && age>=0 && age<=8000 && [activity[@"inputIdleMs"] doubleValue]>=age && ![activity[@"inputStamp"] isEqual:@"unknown"] && [activity[@"inputStamp"] isEqualToString:@(argv[5])] && [args[@"known"] boolValue] && [args[@"plain"] boolValue] && args[@"port"]==NSNull.null;
        output(@{@"accepted":(safe && [a terminate]) ? @YES : @NO}); return 0;
    }
    if ([action isEqualToString:@"launch"] && (argc==5||argc==6)) {
        NSDictionary *current=snapshot(path);
        BOOL restore=argc==6 && strcmp(argv[5],"restore")==0;
        if ([current[@"apps"] count] || (!restore && (![current[@"inputStamp"] isEqualToString:@(argv[3])] || [current[@"frontmostPid"] intValue]!=atoi(argv[4])))) { output(@{@"launched":@NO}); return 0; }
        NSWorkspaceOpenConfiguration *config=NSWorkspaceOpenConfiguration.configuration;
        // Do not launch hidden: a later input/focus change must not strand the app.
        config.activates=NO; config.hides=NO; config.addsToRecentItems=NO;
        config.arguments=@[@"--remote-debugging-address=127.0.0.1", @"--remote-debugging-port=39222"];
        __block BOOL done=NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:path] configuration:config completionHandler:^(NSRunningApplication *a,NSError *e){
            output(e ? @{@"launched":@NO, @"errorCode":@(e.code)} : @{@"launched":@YES, @"pid":@(a.processIdentifier), @"key":identity(a)}); done=YES;
        }];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];
        while (!done && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        return done?0:3;
    }
    if ([action isEqualToString:@"show"] && argc==7) {
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];
        BOOL mayActivate=atoi(argv[6])>=0;
        while (deadline.timeIntervalSinceNow>0) {
        NSRunningApplication *a=[NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[3])];
        NSDictionary *args = a ? argumentsState(a.processIdentifier) : @{};
        double age = a.launchDate ? (NSDate.date.timeIntervalSince1970-a.launchDate.timeIntervalSince1970)*1000 : INFINITY;
        BOOL safe=matches(a,path) && age>=0 && age<=60000 && [identity(a) isEqualToString:@(argv[4])] && [args[@"known"] boolValue] && [args[@"port"] isEqual:@"39222"];
        if (!safe) { output(@{@"shown":@NO,@"activated":@NO,@"reason":@"identity-or-arguments"}); return 0; }
        pid_t front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        if (![inputStamp() isEqualToString:@(argv[5])] || (front!=atoi(argv[6]) && front!=a.processIdentifier)) mayActivate=NO;
        if (a.finishedLaunching) {
            [a unhide];
            front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
            BOOL activate=mayActivate && [inputStamp() isEqualToString:@(argv[5])] && (front==atoi(argv[6]) || front==a.processIdentifier);
            BOOL activated=activate && [a activateWithOptions:NSApplicationActivateAllWindows];
            output(@{@"shown":a.hidden ? @NO : @YES,@"activated":activated ? @YES : @NO,@"reason":activated ? @"visible-and-active" : @"visible-without-focus"}); return 0;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        output(@{@"shown":@NO,@"activated":@NO,@"reason":@"window-timeout"}); return 0;
    }
    return 2;
} }

int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc<3)return 2;
    if(strcmp(argv[1],"serve")!=0)return handleAction(argc,argv);
    NSString *path=canonical(@(argv[2]));
    NSApplication *application=NSApplication.sharedApplication;
    [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
    monitoringClient=YES;clientInputs=[NSMutableDictionary dictionary];sampleClientActivity(path);
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer){(void)timer;sampleClientActivity(path);}];
    // All native actions and samples run on the main thread; stdin waits off-thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        char *line=NULL;size_t size=0;
        while(getline(&line,&size,stdin)>0) {
            NSData *data=[[@(line) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *request=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            dispatch_async(dispatch_get_main_queue(),^{ @autoreleasepool {
                requestId=request[@"id"];
                NSArray *args=request[@"args"];
                if(!requestId||![args isKindOfClass:NSArray.class]||args.count<2||![canonical(args[1]) isEqualToString:path]) {
                    output(@{@"error":@"Invalid native request"});requestId=nil;return;
                }
                NSMutableArray *values=[NSMutableArray arrayWithObject:@"bridge"];
                [values addObjectsFromArray:args];
                const char **nativeArgs=calloc(values.count,sizeof(char *));
                for(NSUInteger i=0;i<values.count;i++)nativeArgs[i]=[values[i] UTF8String];
                @try { int result=handleAction((int)values.count,nativeArgs);if(result)output(@{@"error":@"Native action failed"}); }
                @catch(NSException *exception) { (void)exception;output(@{@"error":@"Native action exception"}); }
                free(nativeArgs);requestId=nil;
            }});
        }
        free(line);dispatch_async(dispatch_get_main_queue(),^{exit(0);});
    });
    [application run];return 0;
} }
