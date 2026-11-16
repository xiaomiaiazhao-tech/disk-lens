import Foundation

func require(_ condition:Bool,_ message:String)throws{if !condition{throw LensError(message)}}
func wait(_ e:DiskEngine)throws{let deadline=Date().addingTimeInterval(20);while e.busy(),Date()<deadline{Thread.sleep(forTimeInterval:0.02)};try require(!e.busy(),"操作超时：\(e.phase) \(e.root) \(e.currentPath) files=\(e.scannedFiles)")}
func selfTest()throws{
    let fm=FileManager.default,root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/real-test-"+UUID().uuidString)
    try fm.createDirectory(at:root.appendingPathComponent("sub"),withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
    let a=root.appendingPathComponent("原件.bin"),b=root.appendingPathComponent("sub/副本.bin"),c=root.appendingPathComponent("不同.bin")
    let data=Data(repeating:65,count:2_097_152);try data.write(to:a);try data.write(to:b);try Data(repeating:66,count:data.count).write(to:c)
    try fm.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:a)
    let e=DiskEngine(persist:false);try e.start(path:root.path);try wait(e)
    try require(e.records.count==3,"文件统计错误")
    let folder=e.directory(root.path);try require(folder["size"] as? Int64==Int64(data.count*3),"目录累计错误")
    try require((e.files(["query":"副本"])["items"] as? [[String:Any]])?.count==1,"搜索错误")
    try e.startHash(minimum:1);try wait(e);try require(e.groups.count==1,"完整查重错误")
    do{_=try e.plan(e.groups[0].ids);throw LensError("未拦截全组删除")}catch let x as LensError where x.message.contains("至少保留"){}
    let id=e.records.values.first{$0.path==b.path}!.id
    let preview=try e.previewTrash([id]);try require(preview["count"] as? Int==1,"审核列表错误")
    let result=try e.trash([id]);try require((result["moved"] as? [[String:Any]])?.count==1,"废纸篓移动失败")
    try require(fm.fileExists(atPath:a.path) && !fm.fileExists(atPath:b.path),"未正确保留原件")
    let restored=try e.restore(e.history[0]["id"] as! String)
    try require(restored["restored"] as? Int==1 && fm.fileExists(atPath:b.path),"恢复失败")
    let entry=e.records.values.first{$0.path==c.path}!
    try Data("changed".utf8).write(to:c)
    do{try e.validate(entry);throw LensError("未拦截文件变化")}catch let x as LensError where x.message.contains("已变化"){}
    try require(e.protectedFile(e.home+"/Pictures/original.heic"),"未保护照片")
    try require(e.protectedFile(e.home+"/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),"未保护 Docker")
    _=try JSONSerialization.data(withJSONObject:e.status());_=try JSONSerialization.data(withJSONObject:e.directory(root.path))
    let fakeHome=root.appendingPathComponent("fake-home"),cache=fakeHome.appendingPathComponent("Library/Developer/Xcode/DerivedData/TestBuild")
    try fm.createDirectory(at:cache,withIntermediateDirectories:true);try Data(repeating:3,count:4096).write(to:cache.appendingPathComponent("generated.o"))
    try fm.createSymbolicLink(at:cache.appendingPathComponent("outside-link"),withDestinationURL:a)
    let managed=DiskEngine(persist:false,testHome:fakeHome.path);try managed.start(path:fakeHome.path);try wait(managed)
    try require(managed.targetRows(category:"build").count==1,"未识别受控构建目录")
    let target=managed.targets.values.first{$0.kind=="cache"}!
    let cacheEntry=managed.records.values.first{$0.path.hasSuffix("generated.o")}!
    try require(try managed.plan([target.id,cacheEntry.id]).count==1,"未合并目录与内部文件的重复选择")
    _=try managed.trash([target.id]);try require(!fm.fileExists(atPath:cache.path)&&fm.fileExists(atPath:a.path),"受控目录移动误跟随符号链接")
    let cacheRestore=try managed.restore(managed.history[0]["id"] as! String);try require(cacheRestore["restored"] as? Int==1,"缓存目录恢复失败")
    try managed.start(path:fakeHome.path);try wait(managed)
    let changedTarget=managed.targets.values.first{$0.kind=="cache"}!
    try Data("new contents".utf8).write(to:cache.appendingPathComponent("generated.o"))
    do{try managed.validateTarget(changedTarget);throw LensError("未拦截目录内部文件变化")}catch let x as LensError where x.message.contains("已变化"){}
    let testApp=fakeHome.appendingPathComponent("Applications/TestOnly.app/Contents")
    try fm.createDirectory(at:testApp,withIntermediateDirectories:true);try Data("test executable".utf8).write(to:testApp.appendingPathComponent("binary"))
    let appRoot=testApp.deletingLastPathComponent();let manifest=try managed.inspectTree(appRoot.path,allowLinks:true)
    let appTarget=Target(id:"app:test",path:appRoot.path,kind:"app",category:"apps",stamp:Stamp(try managed.info(appRoot.path)),expected:manifest,size:15)
    managed.targets[appTarget.id]=appTarget
    try managed.validateTarget(appTarget);_=try managed.trash([appTarget.id]);try require(!fm.fileExists(atPath:appRoot.path),"测试应用包移动失败")
    _=try managed.restore(managed.history[0]["id"] as! String);try require(fm.fileExists(atPath:appRoot.path),"测试应用包恢复失败")
    let goCache=fakeHome.appendingPathComponent("Library/Caches/go-build")
    try fm.createDirectory(at:goCache,withIntermediateDirectories:true);try Data("cache".utf8).write(to:goCache.appendingPathComponent("entry"))
    try managed.start(path:goCache.path);try wait(managed)
    let rootTarget=managed.targets.values.first{$0.path==goCache.path}!
    _=try managed.trash([rootTarget.id]);try require((managed.disk()["total"] as? Int64 ?? 0)>0,"移走扫描根目录后磁盘容量失效")
    _=try managed.restore(managed.history[0]["id"] as! String)
    try fm.linkItem(at:a,to:root.appendingPathComponent("hardlink"))
    try e.start(path:root.path);try wait(e);try e.startHash(minimum:1);try wait(e)
    try require(e.groups.isEmpty,"硬链接被错误计入可清理重复量")
    let stored=DiskEngine(persist:true,testHome:fakeHome.path);stored.history=managed.history;stored.saveHistory()
    let loaded=DiskEngine(persist:true,testHome:fakeHome.path);try require(loaded.history.count==managed.history.count,"清理记录未正确持久化")
    let volume=root.appendingPathComponent("test-volume"),owner=volume.appendingPathComponent("Users/me")
    let ownerCache=owner.appendingPathComponent("Library/Developer/Xcode/DerivedData/Test")
    try fm.createDirectory(at:ownerCache,withIntermediateDirectories:true)
    try fm.createDirectory(at:owner.appendingPathComponent("Downloads"),withIntermediateDirectories:true)
    try fm.createDirectory(at:owner.appendingPathComponent("Documents"),withIntermediateDirectories:true)
    try fm.createDirectory(at:volume.appendingPathComponent("Users/another"),withIntermediateDirectories:true)
    try Data(repeating:1,count:1024).write(to:ownerCache.appendingPathComponent("small-cache"))
    try Data(repeating:3,count:32).write(to:owner.appendingPathComponent("Downloads/tiny"))
    try data.write(to:owner.appendingPathComponent("Documents/large"))
    try data.write(to:volume.appendingPathComponent("Users/another/private-large"))
    let sparse=owner.appendingPathComponent("Docker.raw");fm.createFile(atPath:sparse.path,contents:nil)
    let handle=try FileHandle(forWritingTo:sparse);try handle.truncate(atOffset:64*1024*1024);try handle.close()
    let full=DiskEngine(persist:false,testHome:owner.path,testDiskRoot:volume)
    try full.start(path:"",mode:"disk");try wait(full)
    try require(full.scannedFiles==5 && full.records.count==3,"全盘小文件聚合或大文件索引错误")
    try require(full.totalBytes==Int64(2*data.count+64*1024*1024+1024+32),"全盘没有累计小文件")
    let foreign=full.records.values.first{$0.path.contains("another")}!
    try require(foreign.keep && !foreign.protectionReason.isEmpty,"未标记其他用户资料")
    do{_=try full.plan([foreign.id]);throw LensError("可选择其他用户资料")}catch let x as LensError where x.message.contains("受保护"){}
    let sparseEntry=full.records.values.first{$0.path==sparse.path}!
    try require(sparseEntry.allocated<sparseEntry.size,"稀疏文件占用统计错误")
    let logicalSparse=full.files(["query":"Docker.raw","minimum":1_048_576])
    try require(logicalSparse["total"] as? Int==1,"逻辑大小查询被占用口径破坏")
    let physicalSparse=full.files(["query":"Docker.raw","minimum":1_048_576,"metric":"allocated"])
    try require(physicalSparse["total"] as? Int==0,"稀疏文件按逻辑容量错误通过占用阈值")
    let zeroSparse=full.files(["query":"Docker.raw","metric":"allocated"])
    try require(zeroSparse["allocated"] as? Int64==sparseEntry.allocated && zeroSparse["size"] as? Int64==sparseEntry.size,"占用合计覆盖了逻辑大小，或零分配回退为逻辑大小")
    let bySpace=full.files(["metric":"allocated"])["items"] as! [[String:Any]]
    try require(bySpace.first?["path"] as? String != sparse.path,"大文件列表仍按稀疏文件逻辑容量排序")
    let categoryRows=full.status()["buckets"] as! [[String:Any]]
    try require(categoryRows.first?["id"] as? String != "docker","类别仍按 Docker 逻辑容量排序")
    let tinyTarget=full.targets.values.first{$0.path==ownerCache.path}!
    _=try full.trash([tinyTarget.id]);try require(full.scannedFiles==4,"未索引缓存目录清理后计数未更新")
    _=try full.restore(full.history[0]["id"] as! String)
    let limited=DiskEngine(persist:false,testHome:owner.path,testDiskRoot:volume);limited.maxFiles=1
    try limited.start(path:"",mode:"disk");try wait(limited)
    try require(limited.scannedFiles==5 && limited.records.count==1 && limited.indexLimited && !limited.capped,"全盘模式被明细索引上限中断")
    let quick=DiskEngine(persist:false,testHome:owner.path)
    try quick.start(path:"",mode:"quick");try wait(quick)
    try require(quick.scannedFiles==2 && !quick.records.values.contains{$0.path.hasPrefix(owner.appendingPathComponent("Documents").path+"/")},"快速检查错误扫描了整个用户目录")
    try require(!quick.protection("/System/Library/test","protected",0).isEmpty,"系统保护原因缺失")
    do{try managed.start(path:"/");throw LensError("未拒绝系统根目录")}catch let x as LensError where x.message.contains("请选择"){}
    let resumeRoot=root.appendingPathComponent("resume-fixture")
    try fm.createDirectory(at:resumeRoot,withIntermediateDirectories:true)
    for n in 0..<800{try Data(repeating:UInt8(n%255),count:128).write(to:resumeRoot.appendingPathComponent("entry-\(n)"))}
    try fm.linkItem(at:resumeRoot.appendingPathComponent("entry-0"),to:resumeRoot.appendingPathComponent("hardlink"))
    let resumable=DiskEngine(persist:false)
    try resumable.start(path:resumeRoot.path)
    let pauseDeadline=Date().addingTimeInterval(10)
    while resumable.sync({resumable.scannedFiles<10}),resumable.busy(),Date()<pauseDeadline{Thread.sleep(forTimeInterval:0.0005)}
    resumable.stop();try wait(resumable)
    try require(resumable.canResume && resumable.phase=="paused" && resumable.scannedFiles>0 && resumable.scannedFiles<801,"没有保留中途扫描位置")
    let partial=resumable.records,partialCount=resumable.scannedFiles,partialBytes=resumable.totalBytes
    let pausedElapsed=resumable.status()["elapsed"] as! Double
    Thread.sleep(forTimeInterval:0.03)
    try require(resumable.status()["elapsed"] as? Double==pausedElapsed,"暂停时间被计入扫描耗时")
    do{try resumable.startHash(minimum:1);throw LensError("暂停扫描允许查重覆盖游标")}catch let x as LensError where x.message.contains("继续完成"){}
    try resumable.sync{
        try resumable.resume()
        try require(resumable.scannedFiles==partialCount && resumable.totalBytes==partialBytes,"继续时清空了已有统计")
    }
    try wait(resumable)
    let baseline=DiskEngine(persist:false);try baseline.start(path:resumeRoot.path);try wait(baseline)
    try require(resumable.scannedFiles==801 && resumable.totalBytes==baseline.totalBytes && resumable.allocatedBytes==baseline.allocatedBytes,"继续后漏计或重复计数，或硬链接重复占用")
    try require(partial.allSatisfy{resumable.records[$0.key]?.path==$0.value.path},"继续时重建了已扫描文件索引")
    try require(!resumable.canResume && resumable.phase=="done","完成后仍显示继续")
    let racing=DiskEngine(persist:false)
    try racing.sync{
        try racing.start(path:resumeRoot.path)
        racing.stop();try require(racing.canResume,"停止未立即显示继续入口")
        try racing.resume();racing.stop();try racing.resume()
    }
    try wait(racing)
    try require(racing.scannedFiles==801 && racing.totalBytes==baseline.totalBytes,"系统读取返回前连续停止继续产生了并发遍历或遗漏")
    do{try resumable.resume();throw LensError("已完成扫描允许继续")}catch let x as LensError where x.message.contains("没有可以继续"){}
    let switching=DiskEngine(persist:false,testHome:owner.path)
    try switching.sync{try switching.start(path:resumeRoot.path);switching.stop()};try wait(switching)
    try require(switching.canResume,"立即停止未保留游标")
    try switching.start(path:owner.path,mode:"quick");try wait(switching)
    try require(switching.scannedFiles==2 && !switching.canResume,"切换范围未清除旧游标")
    try switching.sync{try switching.start(path:resumeRoot.path);switching.stop()};try wait(switching)
    switching.sync{switching.invalidateResume();switching.needsRescan=true}
    do{try switching.resume();throw LensError("失效扫描允许继续")}catch let x as LensError where x.message.contains("没有可以继续"){}
    let replacedRoot=root.appendingPathComponent("replace-root"),replacedOld=root.appendingPathComponent("replace-old")
    try fm.createDirectory(at:replacedRoot,withIntermediateDirectories:true)
    let replaced=DiskEngine(persist:false)
    try replaced.sync{try replaced.start(path:replacedRoot.path);replaced.stop()};try wait(replaced)
    try fm.moveItem(at:replacedRoot,to:replacedOld);try fm.createDirectory(at:replacedRoot,withIntermediateDirectories:true)
    do{try replaced.resume();throw LensError("替换后的根目录允许继续")}catch let x as LensError where x.message.contains("已替换"){}
    try require(!replaced.canResume,"根目录替换后仍允许继续")
    // Retain the same enumerator through repeated pauses, including a root boundary.
    let repeated=DiskEngine(persist:false,testHome:owner.path)
    try repeated.sync{try repeated.start(path:owner.path);repeated.stop()};try wait(repeated)
    for _ in 0..<3{try repeated.sync{try repeated.resume();repeated.stop()};try wait(repeated);try require(repeated.canResume,"多次暂停丢失位置")}
    try repeated.resume();try wait(repeated)
    let oneShot=DiskEngine(persist:false,testHome:owner.path);try oneShot.start(path:owner.path);try wait(oneShot)
    try require(repeated.scannedFiles==oneShot.scannedFiles && repeated.totalBytes==oneShot.totalBytes,"优先根目录继续后被重复遍历")
    print("PASS: scan, full-volume aggregation, protection, hashing, safe Trash and restore; resume from partial progress, stable IDs, hardlink totals, paused elapsed time, repeated pause, scope switching and invalidation. All mutations used disposable fixtures only.")
}
