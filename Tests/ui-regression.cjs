const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2]||__dirname+'/../Web/app.js','utf8').replace(/\ninit\(\);?\s*$/,'');
const element={addEventListener(){},children:[],querySelector(){return null;}};
const context=vm.createContext({ICONS:{},window:{},document:{getElementById(){return element;},addEventListener(){},querySelectorAll(){return[];}},setTimeout,clearTimeout,console});
vm.runInContext(source,context);
vm.runInContext(`
const docker={id:'docker',path:'/test/Docker.raw',name:'Docker.raw',size:549755813888,allocated:34359738368,modified:0,hardlink:false,canTrash:false,protectionReason:'Docker 虚拟磁盘',type:'file',count:1,level:'protected',icon:'file',why:'Docker',impact:'保护'};
state.summary={phase:'done',mode:'disk',root:'/',files:1,bytes:docker.size,allocated:docker.allocated,disk:{name:'Mac',total:1099511627776,used:422000000000,free:72000000000},buckets:[docker],errors:[]};
state.prefs={largeMinimum:104857600};state.files={total:1,size:docker.size,allocated:docker.allocated,items:[docker]};state.bucket='docker';
globalThis.detailHtml=fileDetails(docker);globalThis.largeHtml=large();globalThis.developerHtml=developer();
globalThis.zeroHtml=fileDetails({...docker,allocated:0});globalThis.unknownHtml=fileDetails({...docker,allocated:undefined});
globalThis.calls=[];api=async(route,args)=>{calls.push({route,args});return state.files;};render=()=>{};state.page='large';
`,context);
assert.match(context.detailHtml,/<div class="detail-size">32 GiB<\/div>/);
assert.match(context.detailHtml,/<dt>逻辑大小<\/dt><dd>512 GiB<\/dd>/);
assert.match(context.detailHtml,/逻辑大小不等于磁盘占用/);
assert.match(context.largeHtml,/<th class="number">占用估算<\/th>/);
assert.match(context.largeHtml,/<td class="number">32 GiB<\/td><td class="number">512 GiB<\/td>/);
assert.match(context.developerHtml,/<div class="detail-size">32 GiB<\/div>/);
assert.match(context.zeroHtml,/<div class="detail-size">0 B<\/div>/);
assert.match(context.unknownHtml,/<div class="detail-size">未统计<\/div>/);
(async()=>{
 await vm.runInContext('loadPage()',context);
 assert.equal(context.calls[0].args.metric,'allocated');
 assert.equal(context.calls[0].route,'files');
 console.log('PASS: real presenters show allocated space, retain labelled logical capacity, handle zero/unknown and request allocated thresholds/sorting.');
})().catch(e=>{console.error(e);process.exitCode=1;});
