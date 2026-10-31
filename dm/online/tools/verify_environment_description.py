#!/usr/bin/env python3
"""Bounded original D2EM parser/local-validator reference on synthetic profiles.

No OS, DLL entry point, game or network is invoked. Generic allocation/copy/free
are private-arena stand-ins. The corpus deliberately has an empty named inventory;
it does not establish named-record semantics, peer compatibility or admission.
Requires the owner's exact original core and development-only Unicorn.
"""
from pathlib import Path
import argparse, struct, json, os
from verify_reference_vectors import Reference, EXPECTED
from unicorn.x86_const import UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8

class EnvReference(Reference):
 def hook(self,mu,pc,size,user):
  rva=pc-self.base
  try:
   if rva==0x53a4d0:
    a,b,n=map(mu.reg_read,(UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8));assert n<=65536
    x,y=bytes(mu.mem_read(a,n)),bytes(mu.mem_read(b,n))
    self.ret(next((u-v for u,v in zip(x,y) if u!=v),0)&0xffffffffffffffff);return
   if rva in (0x53a4e0,0x53a4f0):
    dst,src,n=map(mu.reg_read,(UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8));assert n<=65536
    if n:mu.mem_write(dst,bytes(mu.mem_read(src,n)))
    self.ret(dst);return
   if rva==0x5136b8:
    n=mu.reg_read(UC_X86_REG_RCX);assert n<=8*1024*1024;self.ret(self.alloc(n));return
   if rva==0x513710:self.ret();return
   super().hook(mu,pc,size,user)
  except Exception as e:self.problem=repr(e);mu.emu_stop()
def baseline():
 return [struct.pack('<HIHHI',2,0,0,4,7),struct.pack('<HBIB',4,3,0,0),b'\x07'+b''.join(struct.pack('<BHBIB',n,4,3,0,0) for n in range(1,8)),b'\x03'+b''.join(struct.pack('<BHBB',n,4,3,0) for n in range(1,4)),b'\x03'+b''.join(struct.pack('<BHBB',n,2,3,0) for n in range(1,4)),b'\0\0']
def envelope(fields):
 body=b''.join(struct.pack('<HI',i+1|0x8000,len(d))+d for i,d in enumerate(fields));return b'D2EM\3\0'+struct.pack('<I',len(body))+body

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--dll',required=True,type=Path)
 parser.add_argument('--vectors',type=Path)
 parser.add_argument('--output',type=Path,help='Create a new synthetic corpus mode0600; never overwrite')
 args=parser.parse_args()
 if not __debug__: parser.error('Run without -O: the bounded reference requires its assertions')
 if args.dll.stat().st_size>32*1024*1024: parser.error('Oversized original core')
 r=EnvReference(args.dll)
 def frame(fields):
  body=b''.join(struct.pack('<HI',i|0x8000,len(d))+d for i,d in fields);return b'D2EM\3\0'+struct.pack('<I',len(body))+body
 base=list(enumerate(baseline(),1));cases=[('unavailable',frame(base))]
 for i,raw in base:
  for n in range(len(raw)):
   cases.append((f'field{i}-truncated-{n}',frame([(j,d[:n] if j==i else d) for j,d in base])))
  cases.append((f'field{i}-trailing-byte',frame([(j,d+b'\0' if j==i else d) for j,d in base])))
  cases.append((f'field{i}-missing',frame([(j,d) for j,d in base if j!=i])))
 def replace(i,raw,name):cases.append((name,frame([(j,raw if j==i else d) for j,d in base])))
 for v in [0,1,2,65535]:
  x=bytearray(base[0][1]);struct.pack_into('<H',x,0,v);replace(1,bytes(x),f'contract-version-{v}')
 for cap in [0,1,2,0xffffffff]:
  for fmt in [0,1,65535]:
   x=bytearray(base[0][1]);struct.pack_into('<IH',x,2,cap,fmt);replace(1,bytes(x),f'sidecar-{cap}-{fmt}')
 for offset,size,values in [(8,'H',[0,1,65535]),(10,'I',[0,1,0xffffffff])]:
  for v in values:
   x=bytearray(base[0][1]);struct.pack_into('<'+size,x,offset,v);replace(1,bytes(x),f'contract-word{offset}-{v}')
 for cov in [0,1,2,3,4,255]:
  for count in [0,1,0xffffffff]:
   for digest in [b'',bytes([42])*32]:
    raw=struct.pack('<HBIB',4,cov,count,len(digest))+digest;replace(2,raw,f'aggregate-{cov}-{count}-{len(digest)}')
 for cov in [0,1,2,3,4,255]:
  for count in [0,1]:
   for digest in [b'',bytes([43])*32]:
    group=struct.pack('<BHBIB',1,4,cov,count,len(digest))+digest
    raw=b'\7'+group+b''.join(struct.pack('<BHBIB',n,4,3,0,0) for n in range(2,8));replace(3,raw,f'group-{cov}-{count}-{len(digest)}')
 for tag in [0,2,7,255]:
  raw=bytearray(base[2][1]);raw[1]=tag;replace(3,bytes(raw),f'group-first-tag-{tag}')
 # Consistent known-data examples are synthetic oracle inputs, not client claims.
 for count in [1,255,65536,0xffffffff]:
  aggregate=struct.pack('<HBIB',4,2,count,32)+bytes([44])*32
  groups=b'\7'+struct.pack('<BHBIB',1,4,1,count,32)+bytes([45])*32+b''.join(struct.pack('<BHBIB',n,4,3,0,0) for n in range(2,8))
  fields=[(i,aggregate if i==2 else groups if i==3 else d) for i,d in base];cases.append((f'consistent-partial-{count}',frame(fields)))
 for cov in [0,1,2,3,4,255]:
  for length in [0,31,32,33]:
   first=struct.pack('<BHBB',1,4,cov,length)+bytes([46])*length
   replace(4,b'\3'+first+b''.join(struct.pack('<BHBB',n,4,3,0) for n in [2,3]),f'bank-{cov}-{length}')
 for cov in [0,1,2,3,4,255]:
  for length in [0,7,8,9]:
   first=struct.pack('<BHBB',1,2,cov,length)+bytes([47])*length
   replace(5,b'\3'+first+b''.join(struct.pack('<BHBB',n,2,3,0) for n in [2,3]),f'schema-{cov}-{length}')
 for i in [2,3,4,5]:
  raw=bytearray(base[i-1][1]);pos=0 if i==2 else 2;raw[pos:pos+2]=b'\0\0';replace(i,bytes(raw),f'field{i}-zero-policy')
 replace(6,struct.pack('<H',257),'named-count-overflow')
 results=[]
 for label,data in cases:
  r.cursor=r.arena;inp=r.alloc(len(data));r.mu.mem_write(inp,data);out=r.alloc(0x500);r.mu.mem_write(out,bytes(0x500))
  accepted=bool(r.run(0x2f7c0,[inp,len(data),out,0],[0])&255)
  results.append({'label':label,'envelopeHex':data.hex(),'accepted':accepted})
 report={'referenceSHA256':EXPECTED,'scope':'Required fields1..6 with empty named inventory; full original parser and local consistency validator, not peer compatibility.','cases':results,'liveAdmissionVerified':False}

 if args.vectors is None and args.output is None:
  args.vectors=Path(__file__).resolve().parents[1]/'Tests/ReimaginedClientTests/Fixtures/required-environment-reference.json'
 if args.vectors:
  raw=args.vectors.read_bytes()
  if len(raw)>8*1024*1024:raise ValueError('Oversized reference corpus')
  expected=json.loads(raw)
  if expected!=report:raise ValueError('Original required-environment corpus mismatch')
 if args.output:
  data=(json.dumps(report,indent=2)+'\n').encode()
  fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'wb') as f:f.write(data)
 print('Original D2EM parser/local validator:',len(results),'synthetic cases matched;',sum(x['accepted'] for x in results),'accepted; no live admission.')

if __name__ == '__main__':
 main()
