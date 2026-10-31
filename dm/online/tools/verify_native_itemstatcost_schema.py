#!/usr/bin/env python3
"""Read exact ARM64 ItemStatCost descriptor initialization without loading tables.

The original bounded initializer prefix runs for editions1..3, stopping before
its first external call. Only private stack/table-manager fixtures are provided.
No OS, table loading, game startup, network or save operation is invoked.
"""
from pathlib import Path
import lz4.block,struct,sys,json,hashlib,argparse
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import UC_ARM64_REG_X0,UC_ARM64_REG_SP,UC_ARM64_REG_LR,UC_ARM64_REG_PC
from check_engine_input import check

def verify_native_schema(p):
 if not __debug__:raise ValueError("Bounded native schema reference requires assertions")
 proof=check(p);d=p.read_bytes();assert hashlib.sha256(d).hexdigest()==proof['inputSha256'];fl=struct.unpack_from('<I',d,12)[0];c=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
 for i in range(3):
  o,a,s=struct.unpack_from('<III',d,0x10+16*i);n=struct.unpack_from('<I',d,0x60+4*i)[0];b=lz4.block.decompress(d[o:o+n],uncompressed_size=s) if fl&(1<<i) else d[o:o+s];c.mem_map(a,(s+4095)&~4095);c.mem_write(a,b)
  if i==2:
   end=(a+s+4095)&~4095;bss=struct.unpack_from('<I',d,0x3c)[0];finish=(a+s+bss+4095)&~4095
   if finish>end:c.mem_map(end,finish-end)
 stack=0x40000000;tables=0x50000000;c.mem_map(stack,0x10000);c.mem_map(tables,0x10000)
 for ed in [1,2,3]:c.mem_write(0x2d64a18+16*ed,struct.pack('<Q',tables))
 def hook(mu,pc,size,user):
  if pc==0x4f881c:mu.emu_stop();return
  if not 0x4f8200<=pc<0x4f881c:raise ValueError('Unexpected native schema initializer instruction '+hex(pc))
 c.hook_add(UC_HOOK_CODE,hook)
 results=[]
 for edition in [1,2,3]:
  c.mem_write(stack,bytes(0x10000));c.reg_write(UC_ARM64_REG_SP,stack+0xf000);c.reg_write(UC_ARM64_REG_X0,edition);c.reg_write(UC_ARM64_REG_LR,0)
  c.emu_start(0x4f8200,0x4f881c,timeout=1000000,count=10000);assert c.reg_read(UC_ARM64_REG_PC)==0x4f881c
  sp=c.reg_read(UC_ARM64_REG_SP);fields=[]
  for i in range(52):
   name,kind,offset,other=struct.unpack('<QQQQ',c.mem_read(sp+0x820+32*i,32))
   if name==0:break
   text=bytes(c.mem_read(name,128)).split(b'\0',1)[0].decode('ascii');fields.append({'name':text,'kindAndMask':kind,'offset':offset,'other':other})
  results.append(fields)
 assert results[0]==results[1]==results[2]
 selected=[f for f in results[0] if f['name'].lower() in ['csvbits','csvparam','csvsigned','save bits','save add','save param bits','valshift']]
 expected={'valshift':(4,20),'save bits':(4,21),'save add':(2,24),'save param bits':(2,32),'csvsigned':((12<<32)|29,4),'csvbits':(4,10),'csvparam':(4,11)}
 assert {f['name']:(f['kindAndMask'],f['offset']) for f in selected}==expected
 instruction=struct.unpack('<I',bytes(c.mem_read(0x4f8854,4)))[0]
 assert instruction&0xffc0001f==0x52800005 and (instruction>>5)&65535==324
 initializer_hash=hashlib.sha256(bytes(c.mem_read(0x4f8200,0x61c))).hexdigest()
 assert initializer_hash=='1690ee777b610c5099e85b0c29b9e8462b4ac7f724cd90f728fff7ac3172dfe0'
 report={'moduleID':proof['moduleID'],'initializerSHA256':hashlib.sha256(bytes(c.mem_read(0x4f8200,0x61c))).hexdigest(),'editionsChecked':[1,2,3],'sameDescriptorLayoutAcrossEditions':True,'rowBytes':324,'fields':selected,'OSCalls':0,'tableOrGameEntryInvoked':False}
 return report

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('main',type=Path)
 args=parser.parse_args()
 if not __debug__:parser.error('Run without -O: bounded reference requires assertions')
 print(json.dumps(verify_native_schema(args.main),indent=2))
