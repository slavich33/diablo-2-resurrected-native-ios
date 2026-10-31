#!/usr/bin/env python3
"""Original stat-descriptor builder and native row-layout reference on synthetic data.

The original name-cache lookup and descriptor builder run; only the immutable
GetTables resource callback, private-arena memory operations and uncontended
locks are stand-ins. No OS, game startup, network, save or resource file runs.
"""
from pathlib import Path
import struct,sys,json,argparse,os
from verify_character_metadata import MetadataReference
from verify_reference_vectors import EXPECTED
from verify_native_itemstatcost_schema import verify_native_schema
from unicorn.x86_const import UC_X86_REG_RCX
class StatReference(MetadataReference):
 def __init__(self,p):
  super().__init__(p);self.rows=0x80000000;self.names=0x82000000;self.resource=self.stop+0x80
  self.mu.mem_map(self.rows,0x1000000);self.mu.mem_map(self.names,0x200000);self.mu.mem_write(self.resource,b'\xc3');self.putq(self.base+0x701e70,self.resource)
 def hook(self,mu,pc,size,user):
  if pc==self.resource:
   assert mu.reg_read(UC_X86_REG_RCX)==self.edition;self.ret(self.manager);return
  if pc-self.base in [0x514108,0x514140]:self.ret(0);return
  super().hook(mu,pc,size,user)
 def descriptor(self,edition,id,row,count,flags,name):
  assert edition in [1,2,3] and 0<=id<=32767 and len(row)==324 and 0<=count<=32768 and flags in [1,2,3]
  self.cursor=self.arena;self.edition=edition;self.manager=self.alloc(0x1300);self.mu.mem_write(self.manager,bytes(0x1300));self.putq(self.manager+0x1258,self.rows);self.putq(self.manager+0x1260,count)
  self.mu.mem_write(self.rows+id*324,row)
  self.mu.mem_write(self.base+0x7de2e0,bytes(4*24))
  if name is not None:
   assert 0<len(name)<=1024
   entry=self.names+32*id;self.mu.mem_write(entry,bytes(32))
   if len(name)>15:
    ptr=self.alloc(len(name)+1);self.mu.mem_write(ptr,name+b'\0');self.putq(entry,ptr);self.putq(entry+0x18,len(name))
   else:self.mu.mem_write(entry,name+b'\0');self.putq(entry+0x18,15)
   self.putq(entry+0x10,len(name));self.mu.mem_write(self.base+0x7de2e0+24*edition,struct.pack('<QQQ',self.names,self.names+32*(id+1),self.names+32*(id+1)))
  masks=self.alloc(8192);self.mu.mem_write(masks,bytes(8192))
  for bit,base in [(2,0),(1,4096)]:
   if flags&bit:self.mu.mem_write(masks+base+id//8,bytes([1<<(id%8)]))
  out=self.alloc(0x280);self.mu.mem_write(out,bytes(0x280));slot=self.alloc(64);self.mu.mem_write(slot,bytes(64));self.mu.mem_write(out+0x228,struct.pack('<QQQ',slot,slot,slot+64))
  ok=bool(self.run(0x3bcb90,[edition,id,masks,out])&255)
  if not ok:return None
  assert self.q(out+0x230)==slot+64
  n=self.q(slot+0x18);p=slot+8 if self.q(slot+0x20)<16 else self.q(slot+8)
  raw=bytes(self.mu.mem_read(slot,64));return {'id':struct.unpack_from('<I',raw)[0],'flags':raw[0x28],'flag':bool(raw[0x3a]),'byte34':raw[0x34],'byte35':raw[0x35],'word30':struct.unpack_from('<I',raw,0x30)[0],'word2c':struct.unpack_from('<I',raw,0x2c)[0],'byte38':raw[0x38],'byte39':raw[0x39],'nameHex':bytes(self.mu.mem_read(p,n)).hex()}
def row():
 d=bytearray(324);struct.pack_into('<I',d,4,0x1000);d[0xa]=17;d[0xb]=9;d[0x14]=4;d[0x15]=23;struct.pack_into('<I',d,0x18,0xfffffff9);struct.pack_into('<I',d,0x20,11);return bytes(d)

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--dll',required=True,type=Path)
 parser.add_argument('--main',required=True,type=Path)
 parser.add_argument('--vectors',type=Path)
 parser.add_argument('--output',type=Path,help='Create mode0600 synthetic corpus without overwriting')
 args=parser.parse_args()
 if not __debug__:parser.error('Run without -O: bounded reference requires assertions')
 if args.dll.stat().st_size>32*1024*1024:parser.error('Oversized original core')
 native=verify_native_schema(args.main)
 cases=[]
 def add(label,edition=3,id=1,data=None,count=None,flags=3,name=b'stat'):
  cases.append((label,edition,id,row() if data is None else bytes(data),id+1 if count is None else count,flags,name))
 for edition in [1,2,3]:
  for id in [0,1,7,8,63,64,255,256,32767]:
   for flags in [1,2,3]:add(f'edition-{edition}-id-{id}-usage-{flags}',edition=edition,id=id,flags=flags)
 for offset in [0x0a,0x0b,0x14,0x15]:
  for value in [0,1,31,255]:
   for flags in [1,2,3]:
    b=bytearray(row());b[offset]=value;add(f'byte-{offset}-{value}-{flags}',data=b,flags=flags)
 for offset in [4,0x18,0x20]:
  for value in [0,1,4095,4096,0x80000000,0xffffffff]:
   for flags in [1,2,3]:
    b=bytearray(row());struct.pack_into('<I',b,offset,value);add(f'word-{offset}-{value}-{flags}',data=b,flags=flags)
 for name in [b'x',b'abcdefghijklmno',b'abcdefghijklmnop',bytes([65])*64,'стат'.encode(),'😀'.encode()]:
  for flags in [1,2,3]:add(f'name-{len(cases)}',name=name,flags=flags)
 add('missing-row',id=1,count=1)
 add('empty-table',id=0,count=0)
 add('missing-resolved-name',name=None)
 r=StatReference(args.dll);results=[]
 for label,edition,id,data,count,flags,name in cases:
  expected=r.descriptor(edition,id,data,count,flags,name)
  results.append({'label':label,'edition':edition,'id':id,'rowCount':count,'rowHex':data.hex(),'usageFlags':flags,'name':name.decode('utf8') if name is not None else None,'descriptor':expected})
 report={'referenceSHA256':EXPECTED,'nativeSchema':native,'scope':'Synthetic cached-table resource, full original name lookup/descriptor builder and exact native column initialization; no live table copy, mod identity, sidecar commit or admission.','cases':results,'liveAdmissionVerified':False}
 if args.vectors is None and args.output is None:args.vectors=Path(__file__).resolve().parents[1]/'Tests/ReimaginedClientTests/Fixtures/character-stat-descriptors-reference.json'
 if args.vectors:
  with args.vectors.open('rb') as file:data=file.read(8*1024*1024+1)
  if len(data)>8*1024*1024 or json.loads(data)!=report:raise ValueError('Original descriptor reference mismatch')
 if args.output:
  fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'wb') as file:file.write((json.dumps(report,indent=2)+'\n').encode())
 print('Original stat descriptors:',len(results),'cases;',sum(c['descriptor'] is not None for c in results),'produced; native schema editions1..3 matched; no live admission.')

if __name__=='__main__':main()
