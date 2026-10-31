#!/usr/bin/env python3
"""Full original sidecar history merge on own synthetic fixtures.

The real decoder/history fold/previous-file SHA256/encoder run. OS clock/RNG
and sign/verify callbacks use explicit deterministic fixtures: this proves the
history algorithm, not the replaced callbacks' cryptography or server admission.
Native CryptoKit signing has its separate original-hash/OpenSSL verification.
"""
from pathlib import Path
import struct,json,argparse,os,hashlib
from verify_sidecar_signing_digest import SigningReference
from verify_character_sidecar import prefix,body,file,stat
from verify_reference_vectors import EXPECTED
from unicorn.x86_const import UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8,UC_X86_REG_R9

class HistoryReference(SigningReference):
 def __init__(self,p):
  super().__init__(p);self.signer=self.stop+0x100;self.verifier=self.stop+0x180
  self.clock=1000*10000000;self.random=bytes(range(1,17));self.calls=[]
 def hook(self,mu,pc,size,user):
  rva=pc-self.base
  if rva==0x539930:self.ret(self.clock & ((1<<64)-1));return
  if rva==0x538d10:
   dst=mu.reg_read(UC_X86_REG_RDX);n=mu.reg_read(UC_X86_REG_R8);assert n==16
   mu.mem_write(dst,self.random);self.ret(0);return
  if pc==self.signer:
   m=mu.reg_read(UC_X86_REG_RCX);expected=mu.reg_read(UC_X86_REG_RDX)
   self.calls.append({'sign':True,'expectedKey':bool(expected),'mode':mu.reg_read(UC_X86_REG_R8)&255})
   if expected:assert bytes(mu.mem_read(expected,64))==bytes([43])*64
   mu.mem_write(m+0x70,bytes([bytes(mu.mem_read(m+0x70,1))[0]&~4]));mu.mem_write(m+0x98,struct.pack('<I',1));mu.mem_write(m+0x9c,bytes([43])*64);mu.mem_write(m+0xdc,bytes([44])*64);self.ret(0);return
  if pc==self.verifier:self.calls.append({'verify':True});self.ret(1);return
  super().hook(mu,pc,size,user)
 def history(self,old,current,flag=False,extra=False):
  self.cursor=self.arena;self.calls=[]
  m,e=self.decode(current);assert m and e==0
  guard=bytes(self.mu.mem_read(m+0x248,0x38))
  ctx=self.alloc(24);self.mu.mem_write(ctx,struct.pack('<QQQ',self.signer,self.verifier,0))
  ok=self.run(0x4f3e40,[self.span(old),int(flag),int(extra),m],[ctx])&255
  if not ok:raise ValueError('Original history merge refused synthetic fixture')
  if bytes(self.mu.mem_read(m+0x248,0x38))!=guard:raise ValueError('Original history merge crossed the complete model allocation')
  output,e=self.encode(m);assert output and e==0
  return output

def metadata(p, flags=0, count=0, first=0, last=0):
 struct.pack_into('<QI',p,128,flags,count);struct.pack_into('<QQ',p,144,first,last)
 return p

def previous(flags=0,count=1,first=403,last=403,contract=(0,0,0,0),root=b''):
 p=prefix();struct.pack_into('<I',p,120,flags);struct.pack_into('<I',p,160,1)
 struct.pack_into('<QQQ',p,64,first,last,count)
 if count>1:p[88:120]=bytes([7])*32
 p[168:232]=bytes([43])*64;p[232:296]=bytes([44])*64
 metadata(p,*contract)
 return file(body(p,root=(root,b''),stats=[stat(id=3,flags=1,name=b'own_stat')] if root else []))

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--dll',type=Path,required=True)
 parser.add_argument('--vectors',type=Path);parser.add_argument('--output',type=Path);args=parser.parse_args()
 if not __debug__:parser.error('Bounded reference requires assertions')
 if args.dll.stat().st_size>32*1024*1024:parser.error('Oversized original core')
 r=HistoryReference(args.dll);inputs=[]
 for ticks in [-10000001,-1,0,1,9999999,10000000,19999999,20000000,4030000000,17934880001234567,9223372036850000000]:
  for flag in [False,True]:
   for extra in [False,True]:inputs.append(('clock-'+str(len(inputs)),b'',file(body()),ticks,flag,extra,'initial'))
 for flags in range(4):
  for now in [1,402,403,404,1000]:
   for extra in [False,True]:inputs.append(('advance-'+str(len(inputs)),previous(flags),file(body()),now*10000000,False,extra,'advance'))
 for flags in range(4,8):
  for now in [50,1000]:
   p=prefix();struct.pack_into('<I',p,120,flags)
   inputs.append(('unsealed-'+str(len(inputs)),file(body(p)),file(body()),now*10000000,False,False,'advance'))
 contracts=[(0,0,0,0),(1,1,1,1),(2,2,2,3),(4,0xfffffffe,3,4),(63,0xffffffff,1,0xffffffffffffffff)]
 for old in contracts:
  for new in contracts:
   for extra in [False,True]:
    current=file(body(metadata(prefix(),*new)))
    inputs.append(('contract-'+str(len(inputs)),previous(contract=old,root=b'own_history'),current,10000000000,False,extra,'advance'))
 inputs.append(('exhausted-count',previous(count=0xffffffffffffffff),file(body()),10000000000,False,False,'resetRequiresExplicitDecision'))
 results=[]
 for label,old,current,ticks,flag,extra,action in inputs:
  r.clock=ticks
  output=r.history(old,current,flag,extra)
  fields=bytearray(output[44:340]);fields[120]|=4;fields[160:296]=bytes(136)
  seconds=(abs(ticks)//10000000)*(1 if ticks>=0 else -1);timestamp=max(1,seconds)
  assert struct.unpack_from('<Q',fields,72)[0]==timestamp
  if action=='advance':assert fields[88:120]==hashlib.sha256(old).digest()
  results.append({'label':label,'action':action,'oldFileHex':old.hex(),'currentFileHex':current.hex(),
   'clockTicks':ticks,'timestamp':timestamp,'initialRestartFlag':flag,'extraFlag':extra,
   'randomIDHex':r.random.hex(),'unsignedFixedFieldsHex':fields.hex(),'callbackTrace':r.calls})
 report={'referenceSHA256':EXPECTED,'scope':'Full original history merge with synthetic OS clock/RNG and sign/verify callbacks; no original signer, game, network or admission.',
  'cases':results,'liveAdmissionVerified':False}
 if args.vectors is None and args.output is None:args.vectors=Path(__file__).resolve().parents[1]/'Tests/ReimaginedClientTests/Fixtures/sidecar-history-reference.json'
 if args.vectors:
  d=args.vectors.read_bytes()
  if len(d)>8*1024*1024 or json.loads(d)!=report:raise ValueError('Original history corpus mismatch')
 if args.output:
  fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'w') as out:json.dump(report,out,indent=2);out.write('\n')
 print('Original sidecar history:',len(results),'own synthetic cases; clock/fold/previous-file SHA256 checked; crypto callbacks are fixtures.')

if __name__=='__main__':main()
