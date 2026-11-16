import Foundation
import CryptoKit
import Darwin

struct LensError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct Stamp: Equatable {
    let dev: Int32, inode: UInt64, size: Int64, mtime: Int64, ctime: Int64
    init(_ s: stat) {
        dev=s.st_dev; inode=s.st_ino; size=s.st_size
        mtime=Int64(s.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(s.st_mtimespec.tv_nsec)
        ctime=Int64(s.st_ctimespec.tv_sec) &* 1_000_000_000 &+ Int64(s.st_ctimespec.tv_nsec)
    }
}
struct Entry {
    let id: String, path: String, size: Int64, allocated: Int64, modified: Double, hardlink: Bool, stamp: Stamp
    let category: String, type: String, keep: Bool
    var protectionReason:String=""
    var group: String?
    var json: [String: Any] { ["id":id,"path":path,"name":(path as NSString).lastPathComponent,"size":size,"allocated":allocated,"modified":modified,"hardlink":hardlink,"category":category,"type":type,"canTrash":!keep,"protectionReason":protectionReason,"group":group as Any? ?? NSNull()] }
}
struct FolderSize { var logical: Int64=0; var allocated: Int64=0; var files=0;var protectedFiles=0;var protectedBytes:Int64=0 }
struct Bucket {
    let id: String, name: String, level: String, icon: String, why: String, impact: String
    var logical: Int64=0; var allocated: Int64=0; var count=0
    var json: [String:Any] { ["id":id,"name":name,"level":level,"icon":icon,"why":why,"impact":impact,"size":logical,"allocated":allocated,"count":count] }
}
struct Group {
    let id: String, sha: String
    var ids: [String]
}
struct Target {
    let id: String, path: String, kind: String, category: String, stamp: Stamp
    let expected: [String:Stamp]
    let size: Int64
    var json: [String:Any] { ["id":id,"path":path,"name":URL(fileURLWithPath:path).lastPathComponent,"kind":kind,"category":category,"size":size,"count":expected.count] }
}

// Owned by one scan worker at a time. Keep the enumerator and inode set across
// pauses so continuing never walks already completed roots or double-counts files.
final class ScanCursor {
    let url:URL, device:Int32, inode:UInt64
    var roots:[URL]=[], initialized=false, rootIndex=0
    var enumerator:FileManager.DirectoryEnumerator?
    var seen:Set<String>=[], covered:Set<String>=[]
    init(_ url:URL,_ s:stat){self.url=url;device=s.st_dev;inode=s.st_ino}
}

final class DiskEngine {
    let fm=FileManager.default, lock=NSRecursiveLock()
    let home:String
    let testDiskRoot:URL?
    var maxFiles=1_000_000
    var root="", phase="idle", started=0.0, finished=0.0, revision=0
    var mode="folder",scanRoots:[String]=[],currentPath=""
    var scannedFiles=0,protectedFiles=0,protectedBytes:Int64=0,otherVolumes=0,indexLimited=false,needsRescan=false
    var directCounts:[String:Int]=[:],managedCandidates:Set<String>=[]
    var writableParents:[String:Bool]=[:]
    private var scanCursor:ScanCursor?
    private var scanWorkerRunning=false
    var pausedSeconds=0.0
    var canResume:Bool{phase=="paused" && scanCursor != nil && !needsRescan}
    var dataRoot:URL{testDiskRoot ?? URL(fileURLWithPath:"/System/Volumes/Data",isDirectory:true)}
    var indexMinimum:Int64{mode=="disk" ? 1_048_576:1}
    let stopLock=NSLock()
    private var stoppedFlag=false
    var stopped:Bool{get{stopLock.lock();defer{stopLock.unlock()};return stoppedFlag}set{stopLock.lock();stoppedFlag=newValue;stopLock.unlock()}}
    var capped=false, skipCount=0, cloudCount=0, hashed=0, candidates=0
    var hashMinimum: Int64=1_048_576
    var hashCompleted=false
    var errors: [[String:String]]=[]
    var records:[String:Entry]=[:], pathIDs:[String:String]=[:], folders:[String:FolderSize]=[:]
    var folderChildren:[String:Set<String>]=[:],fileChildren:[String:Set<String>]=[:]
    var buckets:[String:Bucket]=[:], groups:[Group]=[], targets:[String:Target]=[:]
    var totalBytes:Int64=0, allocatedBytes:Int64=0
    var appRows:[[String:Any]]=[], appPhase="idle"
    var history:[[String:Any]]=[]
    var persist=true
    var storage:URL { URL(fileURLWithPath:home,isDirectory:true).appendingPathComponent("Library/Application Support/空间镜",isDirectory:true) }
    init(persist:Bool=true,testHome:String?=nil,testDiskRoot:URL?=nil) {
        self.home=testHome ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.testDiskRoot=testDiskRoot
        self.persist=persist; resetBuckets()
        if persist, let data=try? Data(contentsOf:storage.appendingPathComponent("history.json")), let rows=try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] { history=rows }
    }
    func sync<T>(_ fn:() throws ->T) rethrows ->T { lock.lock();defer{lock.unlock()};return try fn() }
    func isStopped()->Bool { stopped }
    func stop(){
        stopped=true
        sync{if phase=="scanning"{phase="paused";finished=Date().timeIntervalSince1970;revision+=1}}
    }
    func invalidateResume(){scanCursor=nil}
    func resume()throws{
        try sync{
            guard canResume,appPhase != "scanning",let cursor=scanCursor else{throw LensError("没有可以继续的扫描；清理、恢复、退出 App 或更换范围后需要重新扫描。")}
            let s:stat
            do{s=try info(cursor.url.path)}catch{scanCursor=nil;revision+=1;throw LensError("原扫描目录无法访问，请重新选择范围扫描。")}
            guard s.st_dev==cursor.device,s.st_ino==cursor.inode else{scanCursor=nil;revision+=1;throw LensError("扫描根目录已替换或磁盘已改变，请重新扫描。")}
            pausedSeconds+=max(0,Date().timeIntervalSince1970-finished)
            finished=0;stopped=false;phase="scanning";revision+=1
            if !scanWorkerRunning{scanWorkerRunning=true;DispatchQueue.global(qos:.utility).async{self.scan(cursor)}}
        }
    }
    func busy()->Bool { sync{scanWorkerRunning || ["scanning","hashing","trashing","restoring"].contains(phase)} }
    func info(_ path:String)throws->stat {var s=stat();guard lstat(path,&s)==0 else{throw LensError("\(path)：\(String(cString:strerror(errno)))")};return s}
    func problem(_ path:String,_ message:String){sync{skipCount+=1;if errors.count<200{errors.append(["path":path,"message":message])}}}
    func within(_ path:String,_ base:String)->Bool{base=="/" ? path.hasPrefix("/"):path==base || path.hasPrefix(base+"/")}
    func normalized(_ path:String)->String{if mode=="disk",testDiskRoot==nil,within(path,"/System/Volumes/Data"){let s=String(path.dropFirst("/System/Volumes/Data".count));return s.isEmpty ? "/":s};return path}
    func isSystem(_ path:String)->Bool{["/System","/Library","/usr","/bin","/sbin","/etc","/private","/dev","/proc","/sys","/opt"].contains{within(path,$0)}}
    func scanExcluded(_ path:String)->Bool{
        if mode=="disk"{return false}
        if isSystem(path){return true}
        if within(path,Bundle.main.bundlePath),Bundle.main.bundlePath.hasSuffix(".app"){return true}
        return path.split(separator:"/").contains{[".git",".Trash",".Trashes","$RECYCLE.BIN"].contains(String($0))}
    }
    func protectedFile(_ path:String)->Bool{
        if within(path,"/Users"),!within(path,home){return true}
        if mode=="disk",!within(path,home){return true}
        if isSystem(path)||path.split(separator:"/").contains(where:{$0.hasSuffix(".app")}){return true}
        if path.split(separator:"/").contains(where:{[".git",".Trash",".Trashes"].contains(String($0))}){return true}
        if path.hasSuffix("/Docker.raw")||path.hasSuffix("/Docker.qcow2"){return true}
        let protectedRoots=["Library/Keychains","Library/Mail","Library/Messages","Library/Application Support/空间镜","Library/Mobile Documents","Library/CloudStorage",".ssh",".gnupg","Pictures","Library/Photos"]
        return protectedRoots.contains{within(path,home+"/"+$0)} || path.split(separator:"/").contains{$0.hasSuffix(".photoslibrary")||$0.hasSuffix(".backupbundle")||$0=="Backups.backupdb"}
    }
    func protection(_ path:String,_ category:String,_ flags:UInt32)->String{
        if flags & 0x20002 != 0{return "文件被锁定或具有不可变标志"}
        if isSystem(path){return "系统目录：仅统计，不提供删除"}
        if (mode=="disk" && !within(path,home)) || (within(path,"/Users") && !within(path,home)){return "非当前用户资料：仅统计"}
        if path.hasSuffix("/Docker.raw")||path.hasSuffix("/Docker.qcow2"){return "Docker 虚拟磁盘：请通过 Docker 管理"}
        if path.split(separator:"/").contains(where:{$0.hasSuffix(".app")}){return "应用包内部文件：请通过应用卸载或受控缓存目录处理"}
        if path.split(separator:"/").contains(where:{[".git",".Trash",".Trashes"].contains(String($0))}){return "Git 或废纸篓内部数据：仅统计"}
        if ["simulators","devices","dependencies","archives"].contains(category){return "开发环境或归档：请通过对应工具管理"}
        if within(path,home+"/Library/CloudStorage")||within(path,home+"/Library/Mobile Documents"){return "云同步目录：避免删除同步到云端"}
        if protectedFile(path){return "个人原件、图库、凭据或应用资料：默认保护"}
        let parent=(path as NSString).deletingLastPathComponent
        let writable:Bool
        if let cached=writableParents[parent]{writable=cached}else{writable=fm.isWritableFile(atPath:parent);writableParents[parent]=writable}
        return writable ? "":"所在目录没有写入权限"
    }
    func resetBuckets(){
        let defs:[(String,String,String,String,String,String)]=[
            ("updates","应用更新缓存","safe","app-window","识别到应用更新框架的安装缓存；请先退出相关应用。","下次更新可能重新下载。"),
            ("build","构建缓存","safe","code","位于明确的构建缓存目录，不包含项目源代码。","后续构建会重新生成，首次编译可能变慢。"),
            ("logs","旧日志","safe","file","用户日志目录中修改时间超过 30 天的日志。","历史诊断记录将不再可用。"),
            ("cache","其他应用缓存","review","broom","缓存目录也可能保存离线附件，请逐项审核。","不保证所有缓存可重新下载；先核对完整路径。"),
            ("installers","下载的安装包与压缩包","review","download-simple","下载目录中的安装介质与压缩包，仅作为审核候选。","请确认已安装或另有备份，不会自动选中。"),
            ("simulators","模拟器数据","review","desktop","开发模拟器的用户数据目录。","默认只查看；通过开发工具管理环境。"),
            ("devices","iOS 设备支持文件","review","desktop","用于设备调试的支持文件。","默认只查看；移除可能影响设备调试。"),
            ("docker","Docker 存储","protected","hard-drives","容器、镜像与数据卷共用的虚拟磁盘。","禁止直接删除虚拟磁盘；请使用 Docker 自身管理资源。"),
            ("dependencies","依赖与工具缓存","review","file-archive","包管理器缓存可能被环境通过链接引用。","默认只查看；优先使用对应工具的缓存清理命令。"),
            ("archives","开发归档","protected","shield-check","发布归档可能用于回溯、符号分析和重新分发。","默认保护，不能批量清理。"),
            ("protected","受保护资料","protected","shield-check","图库、凭据、邮件、云同步数据和应用包内容默认保护。","不加入清理列表。"),
            ("user","其他用户文件","review","folder","普通用户文件，需要结合内容和用途判断。","移到废纸篓前核对原件与备份。")]
        buckets=Dictionary(uniqueKeysWithValues:defs.map{($0.0,Bucket(id:$0.0,name:$0.1,level:$0.2,icon:$0.3,why:$0.4,impact:$0.5))})
    }
    func category(_ path:String,modified:Double)->String{
        if path.hasSuffix("/Docker.raw")||path.hasSuffix("/Docker.qcow2"){return "docker"}
        if path.contains("/org.sparkle-project.Sparkle/Installation/") && within(path,home+"/Library/Caches"){return "updates"}
        if within(path,home+"/Library/Caches/BaiduMacHi/HiUpdate"){return "updates"}
        if ["Library/Developer/Xcode/DerivedData","Library/Caches/go-build",".cache/swe-batch/gobuild"].contains(where:{within(path,home+"/"+$0)}){return "build"}
        if within(path,home+"/Library/Logs"),modified<Date().timeIntervalSince1970-30*86400{return "logs"}
        if within(path,home+"/Library/Developer/CoreSimulator"){return "simulators"}
        if within(path,home+"/Library/Developer/Xcode/iOS DeviceSupport"){return "devices"}
        if within(path,home+"/Library/Developer/Xcode/Archives"){return "archives"}
        if [".cache/uv",".gradle",".npm","Library/pnpm",".cache/huggingface"].contains(where:{within(path,home+"/"+$0)}){return "dependencies"}
        if protectedFile(path){return "protected"}
        if within(path,home+"/Library/Caches"){return "cache"}
        if within(path,home+"/Downloads"),["zip","dmg","pkg","tar","gz","7z","rar"].contains((path as NSString).pathExtension.lowercased()){return "installers"}
        return "user"
    }
    func fileType(_ path:String)->String{
        let ext=(path as NSString).pathExtension.lowercased()
        if ["mov","mp4","mkv","avi","m4v","webm"].contains(ext){return "video"}
        if ["zip","rar","gz","tar","7z","xz","bz2"].contains(ext){return "archive"}
        if ["dmg","pkg","iso"].contains(ext){return "installer"}
        if ["jpg","jpeg","png","heic","gif","tiff","webp"].contains(ext){return "image"}
        return "file"
    }
    func addFolder(_ e:Entry,delta:Int64=1,indexed:Bool=true){
        var path=(e.path as NSString).deletingLastPathComponent
        path.makeContiguousUTF8()
        directCounts[path,default:0]+=Int(delta)
        if indexed{if delta>0{fileChildren[path,default:[]].insert(e.id)}else{fileChildren[path]?.remove(e.id)}}
        while within(path,root){
            var parent=(path as NSString).deletingLastPathComponent
            parent.makeContiguousUTF8()
            if folders[path]==nil,path != root,within(parent,root){folderChildren[parent,default:[]].insert(path)}
            var f=folders[path] ?? FolderSize();f.logical+=e.size*delta;f.allocated+=e.allocated*delta;f.files+=Int(delta);if e.keep{f.protectedFiles+=Int(delta);f.protectedBytes+=e.size*delta};folders[path]=f
            if path==root||parent==path{break};path=parent
        }
    }
    func start(path:String,mode requested:String="folder")throws{
        try sync{
            guard !busy(),appPhase != "scanning" else{throw LensError("当前检查或应用统计尚未结束，请先等待或停止。")}
            guard ["quick","disk","folder"].contains(requested)else{throw LensError("扫描模式无效")}
            let url=requested=="disk" ? dataRoot:URL(fileURLWithPath:((requested=="quick" ? home:path) as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            var dir:ObjCBool=false
            guard (requested=="disk" || (url.path != "/" && !isSystem(url.path))),fm.fileExists(atPath:url.path,isDirectory:&dir),dir.boolValue else{throw LensError("请选择可访问的用户目录或使用内部数据盘分析入口。")}
            let cursor=ScanCursor(url,try info(url.path))
            scanCursor=cursor;pausedSeconds=0;scanWorkerRunning=true
            mode=requested;root=requested=="disk" ? (testDiskRoot?.path ?? "/"):url.path;phase="scanning";started=Date().timeIntervalSince1970;finished=0;stopped=false;capped=false
            scannedFiles=0;protectedFiles=0;protectedBytes=0;otherVolumes=0;indexLimited=false;needsRescan=false;directCounts=[:];managedCandidates=[];writableParents=[:];scanRoots=[];currentPath=root
            records=[:];pathIDs=[:];folders=[root:FolderSize()];folderChildren=[:];fileChildren=[:];groups=[];targets=targets.filter{$0.value.kind=="app"};errors=[];skipCount=0;cloudCount=0;hashed=0;candidates=0;hashCompleted=false;totalBytes=0;allocatedBytes=0;revision+=1;resetBuckets()
            DispatchQueue.global(qos:.utility).async{self.scan(cursor)}
        }
    }
    func scan(_ cursor:ScanCursor){
        let url=cursor.url
        if !cursor.initialized{
            let preferred=(mode=="quick" || url.path==home) ? ["Library/Caches","Library/Developer","Downloads","Library/Logs"].map{URL(fileURLWithPath:home,isDirectory:true).appendingPathComponent($0,isDirectory:true)}.filter{u in guard let s=try? info(u.path)else{return false};return s.st_mode&S_IFMT==S_IFDIR}:[]
            cursor.roots=mode=="quick" ? preferred:preferred+[url];cursor.initialized=true
            sync{scanRoots=cursor.roots.map{normalized($0.path)}}
        }
        while cursor.rootIndex<cursor.roots.count && !isStopped() && !sync({capped}){
            let scanRoot=cursor.roots[cursor.rootIndex]
            if cursor.enumerator==nil{
                cursor.enumerator=fm.enumerator(at:scanRoot,includingPropertiesForKeys:nil,options:[],errorHandler:{u,e in self.problem(u.path,e.localizedDescription);return true})
                if cursor.enumerator==nil{problem(scanRoot.path,"无法打开目录");cursor.rootIndex+=1;continue}
            }
            guard let en=cursor.enumerator else{break}
            guard let item=en.nextObject() as? URL else{
                cursor.covered.insert(normalized(scanRoot.path));cursor.enumerator=nil;cursor.rootIndex+=1;continue
            }
            var rawPath=item.path;rawPath.makeContiguousUTF8()
            var path=normalized(rawPath);path.makeContiguousUTF8()
            if cursor.covered.contains(path){en.skipDescendants();continue}
            if scanExcluded(path){en.skipDescendants();continue}
            do{
                let s=try info(rawPath),type=s.st_mode&S_IFMT
                if type==S_IFLNK{en.skipDescendants();continue}
                if mode=="disk",s.st_dev != cursor.device{if type==S_IFDIR{en.skipDescendants();sync{otherVolumes+=1}};continue}
                if type==S_IFDIR{sync{currentPath=path};continue}
                guard type==S_IFREG else{continue}
                if s.st_flags & 0x40000000 != 0{sync{cloudCount+=1};continue}
                let modified=Double(s.st_mtimespec.tv_sec),cat=category(path,modified:modified)
                let reason=protection(path,cat,s.st_flags)
                let shouldIndex=mode != "disk" || s.st_size>=indexMinimum
                let e=Entry(id:shouldIndex ? UUID().uuidString:"",path:path,size:s.st_size,allocated:Int64(s.st_blocks)*512,modified:modified,hardlink:s.st_nlink>1,stamp:Stamp(s),category:cat,type:fileType(path),keep:!reason.isEmpty,protectionReason:reason,group:nil)
                let key="\(s.st_dev):\(s.st_ino)",unique=cursor.seen.insert(key).inserted
                let cap=sync{()->Bool in
                    let indexed=shouldIndex && records.count<maxFiles
                    if indexed{records[e.id]=e;pathIDs[path]=e.id}else if shouldIndex{indexLimited=true}
                    scannedFiles+=1;totalBytes+=e.size;if unique{allocatedBytes+=e.allocated};if e.keep{protectedFiles+=1;protectedBytes+=e.size}
                    addFolder(e,indexed:indexed);buckets[cat]?.logical+=e.size;buckets[cat]?.allocated+=e.allocated;buckets[cat]?.count+=1
                    if ["updates","build"].contains(cat),let managed=cacheRoot(for:path){managedCandidates.insert(managed)}
                    return mode != "disk" && records.count>=maxFiles
                }
                if cap{sync{capped=true};problem(root,"达到一百万个文件上限，当前结果不完整，请缩小扫描范围。");break}
            }catch{problem(path,error.localizedDescription)}
        }
        if !isStopped(),!sync({capped}){
            sync{targets=targets.filter{$0.value.kind=="app"}}
            prepareManagedTargets()
        }
        sync{
            // Resume can arrive while the old worker is returning from an OS
            // directory read. Reuse it, or dispatch its remaining cursor, never
            // start two enumerators and never mark an unfinished walk complete.
            if !stopped && !capped && cursor.rootIndex<cursor.roots.count{
                DispatchQueue.global(qos:.utility).async{self.scan(cursor)}
                return
            }
            scanWorkerRunning=false
            phase=capped ? "cancelled":stopped ? "paused":"done"
            if phase != "paused"{scanCursor=nil}
            if phase != "paused" || finished==0{finished=Date().timeIntervalSince1970};revision+=1
        }
    }
    func validate(_ e:Entry)throws{
        guard !e.keep,!scanExcluded(e.path),!protectedFile(e.path),URL(fileURLWithPath:e.path).resolvingSymlinksInPath().path==e.path else{throw LensError("此文件受保护或路径已变化：\(e.path)")}
        let s=try info(e.path);guard s.st_mode&S_IFMT==S_IFREG,Stamp(s)==e.stamp else{throw LensError("文件已变化，请重新扫描：\(e.path)")}
    }
    func unchanged(_ e:Entry)->Bool{(try? validate(e)) != nil}
    func digest(_ e:Entry,prefix:Bool)throws->String{
        try validate(e);let fd=open(e.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw LensError("无法读取 \(e.path)")}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? file.close()};var s=stat();guard fstat(fd,&s)==0,Stamp(s)==e.stamp else{throw LensError("文件已变化")}
        var h=SHA256();while !isStopped(){let bytes=try file.read(upToCount:prefix ? 65536:1048576) ?? Data();if bytes.isEmpty{break};h.update(data:bytes);if prefix{break}}
        guard !isStopped() else{throw LensError("已停止")};guard fstat(fd,&s)==0,Stamp(s)==e.stamp else{throw LensError("读取过程中发生变化")};try validate(e)
        return h.finalize().map{String(format:"%02x",$0)}.joined()
    }
    func startHash(minimum:Int64)throws{
        try sync{
            guard !canResume else{throw LensError("请先继续完成本次扫描，再启动完整内容查重。")}
            guard ["done","cancelled"].contains(phase),!records.isEmpty else{throw LensError("请先完成一次文件扫描。")}
            guard minimum>=indexMinimum else{throw LensError("内部数据盘分析只保留 1 MiB 及以上文件明细；检查更小文件请单独扫描目标目录。")}
            phase="hashing";stopped=false;hashed=0;groups=[];hashCompleted=false;hashMinimum=minimum
            for id in records.keys{records[id]?.group=nil}
            let snapshot=records.values.filter{!$0.keep && !$0.hardlink && $0.size>=minimum && !["cache","build","updates","logs"].contains($0.category)}
            DispatchQueue.global(qos:.utility).async{self.hashEntries(snapshot)}
        }
    }
    func hashEntries(_ snapshot:[Entry]){
        let sizes=Dictionary(grouping:snapshot,by:{$0.size}).values.filter{$0.count>1}
        sync{candidates=sizes.reduce(0){$0+$1.count}}
        for same in sizes{
            if isStopped(){break};var prefixes:[String:[Entry]]=[:]
            for e in same{if isStopped(){break};do{prefixes[try digest(e,prefix:true),default:[]].append(e)}catch{if !isStopped(){problem(e.path,error.localizedDescription)}};sync{hashed+=1}}
            for pre in prefixes.values where pre.count>1{
                if isStopped(){break};var full:[String:[Entry]]=[:]
                for e in pre{if isStopped(){break};do{full[try digest(e,prefix:false),default:[]].append(e)}catch{if !isStopped(){problem(e.path,error.localizedDescription)}}}
                for (sha,matches) in full where matches.count>1{let gid=UUID().uuidString;sync{for e in matches{records[e.id]?.group=gid};groups.append(Group(id:gid,sha:sha,ids:matches.map(\.id)))}}
            }
        }
        sync{hashCompleted = !stopped;phase=stopped ? "cancelled":"done";revision+=1;finished=Date().timeIntervalSince1970}
    }
    func disk()->[String:Any]{
        var path=sync{mode=="disk" ? dataRoot.path:(root.isEmpty ? home:root)}
        while !fm.fileExists(atPath:path),path != "/"{path=URL(fileURLWithPath:path).deletingLastPathComponent().path}
        let a=(try? fm.attributesOfFileSystem(forPath:path)) ?? [:]
        let total=(a[.systemSize] as? NSNumber)?.int64Value ?? 0,free=(a[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let volume=(try? URL(fileURLWithPath:path).resourceValues(forKeys:[.volumeNameKey]))?.volumeName ?? "本机磁盘"
        return ["total":total,"free":free,"used":total-free,"name":volume]
    }
    func status()->[String:Any]{let d=disk();return sync{
        let extra=groups.reduce(Int64(0)){n,g in n+(g.ids.compactMap{records[$0]}.first?.size ?? 0)*Int64(max(0,g.ids.count-1))}
        let elapsed=max(0,(finished>0 ? finished:Date().timeIntervalSince1970)-started-pausedSeconds)
        return ["phase":phase,"canResume":canResume,"readInFlight":phase=="paused" && scanWorkerRunning,"resumeScope":"session","root":root,"mode":mode,"scanRoots":scanRoots,"currentPath":currentPath,"home":home,"files":scannedFiles,"indexedFiles":records.count,"indexMinimum":indexMinimum,"indexLimited":indexLimited,"protectedFiles":protectedFiles,"protectedBytes":protectedBytes,"otherVolumes":otherVolumes,"needsRescan":needsRescan,"elapsed":started>0 ? elapsed:0,"speed":elapsed>0 ? Double(scannedFiles)/elapsed:0,"bytes":totalBytes,"allocated":allocatedBytes,"skipped":skipCount,"cloudSkipped":cloudCount,"errors":errors,"capped":capped,"started":started,"finished":finished,"revision":revision,"hashed":hashed,"candidates":candidates,"hashCompleted":hashCompleted,"groupCount":groups.count,"duplicateBytes":extra,"hashMinimum":hashMinimum,"disk":d,"buckets":buckets.values.filter{$0.count>0}.sorted{$0.allocated>$1.allocated}.map(\.json),"appPhase":appPhase,"targetCount":targets.values.filter{$0.kind=="cache"}.count]
    }}
    func files(_ args:[String:Any])->[String:Any]{
        let query=(args["query"] as? String ?? "").lowercased(),cat=args["category"] as? String ?? "",type=args["type"] as? String ?? "all",minimum=(args["minimum"] as? NSNumber)?.int64Value ?? 0,offset=max(0,args["offset"] as? Int ?? 0)
        let allocatedMetric=args["metric"] as? String=="allocated"
        func measure(_ e:Entry)->Int64{allocatedMetric ? e.allocated:e.size}
        let snapshot=sync{Array(records.values)}
        let rows=snapshot.filter{(query.isEmpty||$0.path.lowercased().contains(query))&&(cat.isEmpty||$0.category==cat)&&(type=="all"||$0.type==type)&&measure($0)>=minimum}.sorted{measure($0)==measure($1) ? $0.path<$1.path:measure($0)>measure($1)}
        let low=min(offset,rows.count);return ["total":rows.count,"size":rows.reduce(Int64(0)){$0+$1.size},"allocated":rows.reduce(Int64(0)){$0+$1.allocated},"metric":allocatedMetric ? "allocated":"logical","indexMinimum":indexMinimum,"items":rows[low..<min(low+100,rows.count)].map(\.json)]
    }
    func directory(_ requested:String)->[String:Any]{sync{
        let path=requested.isEmpty ? root:requested
        guard !root.isEmpty,within(path,root) else{return ["path":root,"size":0,"items":[]]}
        var children:[[String:Any]]=[]
        for p in folderChildren[path] ?? []{
            guard let f=folders[p],f.files>0 else{continue}
            children.append(["id":p,"path":p,"name":(p as NSString).lastPathComponent,"size":f.logical,"allocated":f.allocated,"files":f.files,"directory":true,"protectedFiles":f.protectedFiles,"protectedBytes":f.protectedBytes,"protectionReason":f.protectedFiles==f.files ? "此目录已读取内容均受保护，仅统计":f.protectedFiles>0 ? "包含受保护文件，请进入下一层查看":""])
        }
        for id in fileChildren[path] ?? []{if let e=records[id]{var row=e.json;row["directory"]=false;children.append(row)}}
        children.sort{($0["allocated"] as? Int64 ?? 0)>($1["allocated"] as? Int64 ?? 0)}
        let f=folders[path] ?? FolderSize()
        return ["path":path,"name":path=="/" ? "内部数据盘":(path as NSString).lastPathComponent,"size":f.logical,"allocated":f.allocated,"files":f.files,"protectedFiles":f.protectedFiles,"totalItems":(folderChildren[path]?.count ?? 0)+(directCounts[path] ?? 0),"indexedItems":children.count,"indexMinimum":indexMinimum,"items":Array(children.prefix(200)),"parent":path==root ? NSNull():(path as NSString).deletingLastPathComponent as Any]
    }}
    func subtractDirectory(_ path:String,category:String){
        guard let removed=folders[path]else{return}
        totalBytes=max(0,totalBytes-removed.logical);allocatedBytes=max(0,allocatedBytes-removed.allocated);scannedFiles=max(0,scannedFiles-removed.files)
        protectedFiles=max(0,protectedFiles-removed.protectedFiles);protectedBytes=max(0,protectedBytes-removed.protectedBytes)
        buckets[category]?.logical-=removed.logical;buckets[category]?.allocated-=removed.allocated;buckets[category]?.count-=removed.files
        var parent=(path as NSString).deletingLastPathComponent
        while within(parent,root){if var f=folders[parent]{f.logical-=removed.logical;f.allocated-=removed.allocated;f.files-=removed.files;f.protectedFiles-=removed.protectedFiles;f.protectedBytes-=removed.protectedBytes;folders[parent]=f};if parent==root{break};let next=(parent as NSString).deletingLastPathComponent;if next==parent{break};parent=next}
    }
    func duplicateRows(offset:Int)->[String:Any]{sync{
        let sorted=groups.sorted{g,h in let a=records[g.ids[0]]?.size ?? 0,b=records[h.ids[0]]?.size ?? 0;return a*Int64(g.ids.count-1)>b*Int64(h.ids.count-1)}
        let low=min(max(0,offset),sorted.count)
        let rows=sorted[low..<min(low+30,sorted.count)].map{g->[String:Any] in let es=g.ids.compactMap{records[$0]}.sorted{$0.path.count<$1.path.count};return ["id":g.id,"sha256":g.sha,"size":es.first?.size ?? 0,"items":es.map(\.json)]}
        return ["total":sorted.count,"items":rows]
    }}
    func saveHistory(){guard persist else{return};do{try fm.createDirectory(at:storage,withIntermediateDirectories:true);let data=try JSONSerialization.data(withJSONObject:sync{history},options:[.prettyPrinted,.sortedKeys]);try data.write(to:storage.appendingPathComponent("history.json"),options:.atomic)}catch{problem(storage.path,"无法保存清理记录："+error.localizedDescription)}}
}
