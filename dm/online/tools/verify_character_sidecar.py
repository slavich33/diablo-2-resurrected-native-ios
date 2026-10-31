#!/usr/bin/env python3
"""Full original version2 sidecar reader/writer and SHA256 on synthetic files.

Bounded desktop development reference only; no DLL entry point, OS API, game,
network, original save or sidecar file is used. Only generic private-arena stack
probe/allocation/copy/fill/compare/free/vector operations are stand-ins. Original
SHA256, field parsing, local consistency checks and file encoding all run.
Does not verify seal authentication/provenance or native gameplay admission.
"""
from pathlib import Path
import struct,json,hashlib,argparse,os
from unicorn import UcError
from unicorn.x86_const import UC_X86_REG_RAX,UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8,UC_X86_REG_R9,UC_X86_REG_RSP,UC_X86_REG_RIP
from verify_character_metadata import MetadataReference
from verify_reference_vectors import EXPECTED
class SidecarReference(MetadataReference):
 def hook(self,mu,pc,size,user):
  rva=pc-self.base
  try:
   if rva==0x5136b8:
    n=mu.reg_read(UC_X86_REG_RCX);assert n<=4*1024*1024;self.ret(self.alloc(n));return
   if rva==0x53a4d0:
    a,b,n=map(mu.reg_read,(UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8));assert n<=65536
    x,y=bytes(mu.mem_read(a,n)),bytes(mu.mem_read(b,n));v=next((u-v for u,v in zip(x,y) if u!=v),0)
    self.ret(v&0xffffffffffffffff);return
   if rva==0x41ada0:
    vec,pos,src,n=map(mu.reg_read,(UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8,UC_X86_REG_R9));assert n<=2*1024*1024
    self.append(vec,pos,src,n);self.ret();return
   super().hook(mu,pc,size,user)
  except Exception as e:self.problem=repr(e);mu.emu_stop()
 def run(self,rva,args,stackargs=()):
  sp=self.stack+0xff008;self.putq(sp,self.stop)
  for i,value in enumerate(stackargs):self.putq(sp+0x28+i*8,value)
  for reg,value in zip((UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8,UC_X86_REG_R9),args):self.mu.reg_write(reg,value)
  self.mu.reg_write(UC_X86_REG_RSP,sp);self.problem=None
  try:self.mu.emu_start(self.base+rva,self.stop,timeout=2_000_000,count=1_000_000)
  except UcError as e:raise RuntimeError(str(e)+' at '+hex(self.mu.reg_read(UC_X86_REG_RIP)))
  if self.problem:raise RuntimeError(self.problem)
  if self.mu.reg_read(UC_X86_REG_RIP)!=self.stop:raise RuntimeError('sidecar reference did not return within bounds')
  return self.mu.reg_read(UC_X86_REG_RAX)
 def encode(self,m):
  v=self.vector();e=self.alloc(4);self.mu.mem_write(e,bytes(4))
  ok=bool(self.run(0xa320,[m,v,e])&255)
  return self.readvec(v) if ok else None,struct.unpack('<I',self.mu.mem_read(e,4))[0]
 def decode(self,d):
  m=self.alloc(0x280);self.mu.mem_write(m,bytes(0x248));guard=bytes([0xa7])*0x38;self.mu.mem_write(m+0x248,guard)
  for x in range(0x120,0x200,0x20):self.putq(m+x+0x18,15)
  e=self.alloc(4);self.mu.mem_write(e,bytes(4));ok=bool(self.run(0xa8a0,[self.span(d),m,e])&255)
  if bytes(self.mu.mem_read(m+0x248,0x38))!=guard:raise ValueError('Original sidecar model crossed its 0x248-byte allocation')
  if ok and bytes(self.mu.mem_read(m+0x240,2))!=b'\2\0':raise ValueError('Original sidecar model lost its file-version field')
  error=struct.unpack('<I',self.mu.mem_read(e,4))[0]
  if ok and error:raise ValueError('Successful original sidecar decode left a nonzero error status')
  return m if ok else None,error
 def readvec(self,p):
  start,end,cap=struct.unpack('<QQQ',self.mu.mem_read(p,24))
  if not start<=end<=cap or end-start>2*1024*1024+44:raise ValueError('Invalid sidecar reference vector')
  return bytes(self.mu.mem_read(start,end-start)) if end>start else b''
def text(t):return struct.pack('<I',len(t))+t
def prefix():
 p=bytearray(296);struct.pack_into('<II',p,8,0x12345678,105);p[16:48]=bytes([42])*32;p[48:64]=b'NativeFixture\0\0\0';struct.pack_into('<QQQ',p,64,403,403,1);struct.pack_into('<I',p,120,4);return p
def plugin(words=(1,1,3,0),flag=0,digest=bytes(32),texts=(b'plugin',b'',b'',b''),reserved=0):
 return struct.pack('<6I',*words,flag,reserved)+digest+b''.join(text(t) for t in texts)
def stat(id=1,flags=3,flag=0,b34=0,b35=0,w30=0,w2c=0,b38=0,b39=0,name=b'stat',reserved=0):
 return struct.pack('<IBBBB IIBBH',id,flags,flag,b34,b35,w30,w2c,b38,b39,reserved)+text(name)
def body(p=None,root=(b'',b''),mod=None,plugins=(),stats=()):
 p=prefix() if p is None else bytearray(p)
 if mod is not None:struct.pack_into('<I',p,0,1)
 out=bytes(p)+b''.join(text(t) for t in root)
 if mod is not None:out+=struct.pack('<II',mod[0],mod[1])+b''.join(text(t) for t in mod[2])
 return out+struct.pack('<I',len(plugins))+b''.join(plugins)+struct.pack('<I',len(stats))+b''.join(stats)
def file(b,version=2,header=44):return b'D2RL'+struct.pack('<HHI',version,header,len(b))+hashlib.sha256(b).digest()+b
base=file(body());cases=[('baseline',base)]
cases += [(f'truncated-{n}',base[:n]) for n in range(len(base))]
for v in [0,2,3,65535]:cases.append((f'version-{v}',file(body(),version=v)))
for h in [0,8,36,43,44,45,65535]:cases.append((f'header-{h}',file(body(),header=h)))
for i in [0,4,8,11,12,43,44,len(base)-1]:
 b=bytearray(base);b[i]^=1;cases.append((f'corrupt-file-{i}',bytes(b)))
for off,fmt,values in [(0,'I',[0,1,2]),(4,'I',[0,1]),(12,'I',[0,1,105,0xffffffff]),(64,'Q',[0,1,403,404,0xffffffffffffffff]),(72,'Q',[0,1,402,403,0xffffffffffffffff]),(80,'Q',[0,1,2,0xffffffffffffffff]),(120,'I',list(range(256))),(124,'I',[0,1]),(128,'Q',[0,1,63,64]),(136,'I',[0,1,0xffffffff]),(140,'I',[0,1]),(144,'Q',[0,1]),(152,'Q',[0,1]),(160,'I',[0,1,2]),(164,'I',[0,1])]:
 for v in values:
  p=prefix();struct.pack_into('<'+fmt,p,off,v);cases.append((f'fixed-{off}-{v}',file(body(p))))
for name in ['sha','name','environment','seal1','seal2']:
 for value in [0,42]:
  p=prefix();a,z={'sha':(16,48),'name':(48,64),'environment':(88,120),'seal1':(168,232),'seal2':(232,296)}[name];p[a:z]=bytes([value])*(z-a);cases.append((f'fixed-bytes-{name}-{value}',file(body(p))))
for flags in range(8):
 p=prefix();struct.pack_into('<I',p,120,flags);struct.pack_into('<I',p,160,1);p[168:296]=bytes([43])*128;cases.append((f'sealed-{flags}',file(body(p))))
for flags in [0,1,63,64]:
 for seq,last in [(0,0),(1,0),(1,1),(2,1),(2,2),(1,0xffffffffffffffff)]:
  p=prefix();struct.pack_into('<Q',p,128,flags);struct.pack_into('<I',p,136,1);struct.pack_into('<QQ',p,144,seq,last);cases.append((f'lineage-{flags}-{seq}-{last}',file(body(p))))
for t in [b'',b'x',bytes([65])*1024,bytes([65])*1025,b'a\0b',b'\xc0\x80','😀'.encode(),'тест'.encode()]:cases.append(('root-text-'+str(len(cases)),file(body(root=(t,b'')))))
for scope in [0,1,2,0xffffffff]:cases.append((f'mod-scope-{scope}',file(body(mod=(scope,0,[b'mod',b'Mod',b'',b'',b''])))))
for which in range(5):
 vals=[b'mod',b'Mod',b'',b'',b''];vals[which]=b'';cases.append((f'mod-empty-{which}',file(body(mod=(0,0,vals)))))
for role in [0,1,2,3]:
 for scope in [0,1,2,3,4]:cases.append((f'plugin-role-scope-{role}-{scope}',file(body(plugins=[plugin(words=(role,scope,0,0))]))))
for flag in [0,1,2]:
 for value in [0,42]:cases.append((f'plugin-digest-{flag}-{value}',file(body(plugins=[plugin(flag=flag,digest=bytes([value])*32)]))))
cases.append(('plugin-reserved',file(body(plugins=[plugin(reserved=1)]))))
cases.append(('plugin-duplicate',file(body(plugins=[plugin(),plugin()]))))
cases.append(('plugin-case-sensitive',file(body(plugins=[plugin(),plugin(texts=(b'Plugin',b'',b'',b''))]))))
for which in range(4):
 for t in [b'',b'text','😀'.encode(),b'a\0b',b'\xff']:
  vals=[b'plugin',b'',b'',b''];vals[which]=t;cases.append((f'plugin-text-{which}-{t.hex()}',file(body(plugins=[plugin(texts=vals)]))))
for id in [0,1,32767,32768,0xffffffff]:cases.append((f'stat-id-{id}',file(body(stats=[stat(id=id)]))))
for flags in range(256):cases.append((f'stat-flags-{flags}',file(body(stats=[stat(flags=flags)]))))
for flag in [0,1,2]:cases.append((f'stat-boolean-{flag}',file(body(stats=[stat(flag=flag)]))))
for field in ['b34','b35','w30','w2c','b38','b39']:
 for flags in [1,2,3]:cases.append((f'stat-field-{field}-{flags}',file(body(stats=[stat(flags=flags,**{field:1})]))))
cases.append(('stat-duplicate',file(body(stats=[stat(),stat()]))))
cases.append(('stat-reserved',file(body(stats=[stat(reserved=1)]))))
for t in [b'',b'x',b'\xff',b'a\0b','😀'.encode()]:cases.append(('stat-text-'+t.hex(),file(body(stats=[stat(name=t)]))))
for n in [1,2,7]:cases.append((f'trailing-{n}',base+bytes(n)))
cases.append(('oversized-plugin-count',file(body()[:-8]+struct.pack('<II',257,0))))
cases.append(('oversized-stat-count',file(body()[:-4]+struct.pack('<I',32769))))

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--dll',required=True,type=Path)
 parser.add_argument('--vectors',type=Path)
 parser.add_argument('--output',type=Path,help='Create mode0600 synthetic corpus, never overwrite')
 args=parser.parse_args()
 if not __debug__:parser.error('Run without -O: bounded reference requires assertions')
 if args.dll.stat().st_size>32*1024*1024:parser.error('Oversized original core')
 r=SidecarReference(args.dll);results=[]
 for label,data in cases:
  r.cursor=r.arena
  try:model,error=r.decode(data)
  except Exception as e:raise RuntimeError('Reference did not complete case '+label) from e
  canonical=None
  if model is not None:
   canonical,error=r.encode(model)
   if canonical is None:raise ValueError('Accepted sidecar model was not encodable: '+label)
  results.append({'label':label,'inputHex':data.hex(),'accepted':model is not None,'canonicalHex':canonical.hex() if canonical is not None else None})
 report={'referenceSHA256':EXPECTED,'scope':'Version2 sidecar file structure and original SHA256/canonical encoding; no seal authentication, provenance or admission.','cases':results,'liveAdmissionVerified':False}
 if args.vectors is None and args.output is None:args.vectors=Path(__file__).resolve().parents[1]/'Tests/ReimaginedClientTests/Fixtures/character-sidecar-reference.json'
 if args.vectors:
  with args.vectors.open('rb') as file:data=file.read(8*1024*1024+1)
  if len(data)>8*1024*1024 or json.loads(data)!=report:raise ValueError('Original sidecar reference corpus mismatch')
 if args.output:
  fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'wb') as file:file.write((json.dumps(report,indent=2)+'\n').encode())
 print('Original version2 sidecar reader/writer/SHA256:',len(results),'synthetic cases;',sum(x['accepted'] for x in results),'accepted; no authenticated sidecar or game admission.')


if __name__ == '__main__':
 main()
