"""Offline encoder reference only; no DLL entry point, game, OS imports or network."""
from pathlib import Path
import struct,hashlib,json
from unicorn import Uc,UC_ARCH_X86,UC_MODE_64,UC_HOOK_CODE,UcError
from unicorn.x86_const import *
EXPECTED='2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2'
class Reference:
 def __init__(self, dll):
  data=Path(dll).read_bytes()
  if hashlib.sha256(data).hexdigest()!=EXPECTED: raise ValueError("Unsupported core: SHA-256 mismatch")
  pe=struct.unpack_from('<I',data,60)[0];opt=pe+24;self.base=struct.unpack_from('<Q',data,opt+24)[0]
  size=struct.unpack_from('<I',data,opt+56)[0];self.mu=Uc(UC_ARCH_X86,UC_MODE_64);self.mu.mem_map(self.base,(size+4095)&~4095)
  self.mu.mem_write(self.base,data[:1024]);self.ranges=[]
  st=opt+struct.unpack_from('<H',data,pe+20)[0]
  for i in range(struct.unpack_from('<H',data,pe+6)[0]):
   s=st+i*40;name=data[s:s+8].split(b'\0')[0];vs,v,rs,off=struct.unpack_from('<IIII',data,s+8)
   self.mu.mem_write(self.base+v,data[off:off+rs])
   if name==b'.text':self.ranges.append((self.base+v,self.base+v+vs))
  self.stack=0x10000000;self.arena=0x30000000;self.stop=0x50000000
  self.mu.mem_map(self.stack,0x100000);self.mu.mem_map(self.arena,0x1000000);self.mu.mem_map(self.stop,4096);self.mu.mem_write(self.stop,b'\xf4')
  self.cursor=self.arena;self.problem=None;self.mu.hook_add(UC_HOOK_CODE,self.hook)
 def q(self,p):return struct.unpack('<Q',self.mu.mem_read(p,8))[0]
 def putq(self,p,v):self.mu.mem_write(p,struct.pack('<Q',v))
 def alloc(self,n):
  p=(self.cursor+31)&~31;self.cursor=p+max(n,32)
  if self.cursor>=self.arena+0x1000000:raise ValueError('reference arena limit')
  return p
 def ret(self,value=0):
  sp=self.mu.reg_read(UC_X86_REG_RSP);target=self.q(sp);self.mu.reg_write(UC_X86_REG_RAX,value);self.mu.reg_write(UC_X86_REG_RSP,sp+8);self.mu.reg_write(UC_X86_REG_RIP,target)
 def reserve(self,vec,n):
  start,end,cap=struct.unpack('<QQQ',self.mu.mem_read(vec,24));used=end-start
  if n>cap-start:
   p=self.alloc(n)
   if used:self.mu.mem_write(p,bytes(self.mu.mem_read(start,used)))
   self.mu.mem_write(vec,struct.pack('<QQQ',p,p+used,p+n))
 def append(self,vec,position,src,n):
  start,end,cap=struct.unpack('<QQQ',self.mu.mem_read(vec,24));
  if position!=end: raise ValueError("Only generic append is supported")
  if end+n>cap:
   self.reserve(vec,max(64,(cap-start)*2,end-start+n));start,end,cap=struct.unpack('<QQQ',self.mu.mem_read(vec,24))
  if n:self.mu.mem_write(end,bytes(self.mu.mem_read(src,n)))
  self.putq(vec+8,end+n)
 def hook(self,mu,pc,size,user):
  try:
   rva=pc-self.base
   if rva==0x452e40:
    self.reserve(mu.reg_read(UC_X86_REG_RCX),self.q(mu.reg_read(UC_X86_REG_RDX)));self.ret();return
   if rva in (0x27f3b0,0x36b760,0x288120):
    vec,pos,src=map(mu.reg_read,(UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8));n=mu.reg_read(UC_X86_REG_R9) if rva==0x27f3b0 else 1
    if n>65536:raise ValueError('reference generic-copy limit')
    self.append(vec,pos,src,n);self.ret();return
   if pc==self.stop:return
   if not any(a<=pc<z for a,z in self.ranges):raise ValueError('reference attempted non-code address '+hex(pc))
   # No x86 syscall instructions may escape even the reference CPU model.
   op=bytes(mu.mem_read(pc,min(size,2)))
   if op in (b'\x0f\x05',b'\x0f\x34',b'\xcd\x80'):raise ValueError('reference OS instruction prohibited')
  except Exception as error:self.problem=str(error);mu.emu_stop()
 def run(self,rva,args,stackargs=()):
  sp=self.stack+0xff008;self.putq(sp,self.stop)
  for i,value in enumerate(stackargs):self.putq(sp+0x28+i*8,value)
  for reg,value in zip((UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8,UC_X86_REG_R9),args):self.mu.reg_write(reg,value)
  self.mu.reg_write(UC_X86_REG_RSP,sp);self.problem=None
  try:self.mu.emu_start(self.base+rva,self.stop,timeout=2_000_000,count=100000)
  except UcError as error:raise RuntimeError(str(error)+' at '+hex(self.mu.reg_read(UC_X86_REG_RIP)))
  if self.problem:raise RuntimeError(self.problem)
  if self.mu.reg_read(UC_X86_REG_RIP)!=self.stop:raise RuntimeError('reference did not return within bounds')
  return self.mu.reg_read(UC_X86_REG_RAX)
 def span(self,data):
  p=self.alloc(len(data));self.mu.mem_write(p,data);s=self.alloc(16);self.mu.mem_write(s,struct.pack('<QQ',p,len(data)));return s
 def vector(self):
  p=self.alloc(24);self.mu.mem_write(p,bytes(24));return p
 def readvec(self,p):
  start,end,cap=struct.unpack('<QQQ',self.mu.mem_read(p,24));
  if not (start<=end<=cap and end-start<=65536+32): raise ValueError("Invalid reference vector bounds")
  return bytes(self.mu.mem_read(start,end-start)) if end>start else b''
 def control(self,kind,data):
  out=self.vector();span=self.span(data);ok=self.run(0x44c040,[kind,span,out]);return bool(ok&255),self.readvec(out)
 def fragment(self,total,offset,data):
  out=self.vector();span=self.span(data);ok=self.run(0x34090,[total,offset,span,out]);return bool(ok&255),self.readvec(out)
 def carrier(self,data):
  out=self.vector();self.run(0x452f20,[out,self.span(data)]);return self.readvec(out)

class SenderReference(Reference):
 """Observe real control send builders at an intercepted queue boundary.

 The queue stand-ins collect bytes, never open a socket or validate admission.
 Generic vector deallocation is a no-op inside the bounded per-case arena.
 """
 def __init__(self,dll):
  super().__init__(dll);self.captured=[]
 def hook(self,mu,pc,size,user):
  try:
   rva=pc-self.base
   if rva==0x453230:  # server control queue(client ID, begin/end span)
    client=mu.reg_read(UC_X86_REG_RCX)&0xffffffff
    span=mu.reg_read(UC_X86_REG_RDX)
    begin,end=struct.unpack('<QQ',mu.mem_read(span,16))
    if not (0<=end-begin<=245):raise ValueError('reference server carrier limit')
    self.captured.append(('server',client,bytes(mu.mem_read(begin,end-begin))));self.ret(1);return
   if rva==0x4530e0:  # client control queue(bytes, count)
    begin=mu.reg_read(UC_X86_REG_RCX);count=mu.reg_read(UC_X86_REG_RDX)
    if not (0<count<=245):raise ValueError('reference client carrier limit')
    self.captured.append(('client',None,bytes(mu.mem_read(begin,count))));self.ret(1);return
   if rva==0x513710:self.ret();return  # generic vector free; private arena
   super().hook(mu,pc,size,user)
  except Exception as error:self.problem=str(error);mu.emu_stop()
 def send(self,direction,kind,data,client=123):
  self.captured=[];span=self.span(data)
  if direction=='server':result=self.run(0x44c140,[client,kind,span])
  elif direction=='client':result=self.run(0x44be50,[kind,span])
  else:raise ValueError('Unknown sender direction')
  ok=bool(result&255)
  if len(self.captured)!=(1 if ok else 0):raise ValueError('Unexpected reference queue call count')
  if ok:
   observed,target,output=self.captured[0]
   if observed!=direction or target!=(client if direction=='server' else None):
    raise ValueError('Unexpected reference queue destination')
  else:output=b''
  return ok,output

if __name__ == '__main__':
 import argparse
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--dll',required=True,help='Local official D2RLoader 1.3.1-beta core; never uploaded')
 parser.add_argument('--vectors',type=Path,default=Path(__file__).resolve().parents[1]/'Tests/ReimaginedClientTests/Fixtures/loader-control-reference.json')
 args=parser.parse_args();corpus=json.loads(args.vectors.read_text())
 if corpus['referenceSHA256']!=EXPECTED: raise ValueError('Unsupported reference corpus')
 r=SenderReference(args.dll)
 for case in corpus['vectors']:
  r.cursor=r.arena;data=bytes.fromhex(case['payloadHex'])
  if case['type']=='control':ok,output=r.control(case['kind'],data)
  elif case['type']=='fragment':ok,output=r.fragment(case['total'],case['offset'],data)
  elif case['type']=='carrier':
   ok,body=r.control(case['kind'],data);output=r.carrier(body) if ok else b''
  elif case['type'] in ('client_send','server_send'):
   ok,output=r.send(case['type'].split('_')[0],case['kind'],data,case.get('clientID',123))
  else:raise ValueError('Unsupported fixture kind')
  if ok!=case['accepted'] or output.hex()!=case['outputHex']:raise ValueError('Reference vector mismatch')
 print('PASS:',len(corpus['vectors']),'official encoder vectors; live game interoperability remains unverified')
