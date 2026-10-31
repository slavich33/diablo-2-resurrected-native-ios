#!/usr/bin/env python3
"""Verify logical system-chunk boundaries against the exact original ARM64 producer.

Development-only Unicorn/lz4 reference: synthetic bytes, bounded original leaf
execution, generic memcpy/memset and queue stand-ins. No OS, network, game entry
or save access. Output, when requested, contains synthetic reference packets, not
captured character data. It does not prove peer TCP/system-format equivalence.
"""
from pathlib import Path
import struct,json,hashlib,argparse,os
from check_engine_input import check
import lz4.block
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2,UC_ARM64_REG_SP,UC_ARM64_REG_LR,UC_ARM64_REG_PC
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('main',type=Path,help='Owned original supported NSO; never uploaded')
parser.add_argument('--output',type=Path,help='Optional synthetic reference JSONL (created mode0600)')
args=parser.parse_args()
if not __debug__:
 parser.error('Run without -O: the bounded reference requires its assertions')
p=args.main;input_proof=check(p);d=p.read_bytes();c=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
for i in range(3):
 off,addr,size=struct.unpack_from('<III',d,16+16*i); compressed=struct.unpack_from('<I',d,12)[0]&(1<<i);n=struct.unpack_from('<I',d,0x60+i*4)[0] if compressed else size
 data=lz4.block.decompress(d[off:off+n],uncompressed_size=size) if compressed else d[off:off+n]
 c.mem_map(addr,(size+4095)&~4095);c.mem_write(addr,data)
 if i==2:
  end=(addr+size+4095)&~4095; bss=struct.unpack_from('<I',d,0x3c)[0]; bss_end=(addr+size+bss+4095)&~4095
  if bss_end>end:c.mem_map(end,bss_end-end)
a,sp,stop=0x40000000,0x50000000,0x60000000
c.mem_map(a,0x100000);c.mem_map(sp,0x10000);c.mem_map(stop,4096)
client,table,entries,body,queue=a,a+0x1000,a+0x2000,a+0x10000,stop+0x100
server=0x2d7f3d8
put64=lambda at,v:c.mem_write(at,struct.pack('<Q',v))
put32=lambda at,v:c.mem_write(at,struct.pack('<I',v))
put64(server,table);put64(table+0x28,queue)
producer_hash=hashlib.sha256(bytes(c.mem_read(0x5d6b80,0x178))).hexdigest()
if producer_hash!='27cdd1481ac15007a89b533509ef91451ae462e43772550f5cd62f3f3f80929c':
 raise ValueError('Unsupported original system producer')
packets=[];final_calls=0
def ret(value=0):
 c.reg_write(UC_ARM64_REG_X0,value);c.reg_write(UC_ARM64_REG_PC,c.reg_read(UC_ARM64_REG_LR))
def hook(_c,pc,size,user):
 global final_calls
 if pc==0x1b76050:
  dst,val,n=(c.reg_read(r) for r in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2))
  assert sp<=dst and dst+n<=sp+0x10000 and n==258
  c.mem_write(dst,bytes([val&255])*n);ret(dst)
 elif pc==0x1b76040:
  dst,src,n=(c.reg_read(r) for r in (UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2))
  assert sp<=dst and dst+n<=sp+0x10000 and a<=src and src+n<=a+0x100000 and n<=255
  c.mem_write(dst,bytes(c.mem_read(src,n)));ret(dst)
 elif pc==queue:
  assert c.reg_read(UC_ARM64_REG_X0)==server and c.reg_read(UC_ARM64_REG_X1)==0x12345678
  ref=c.reg_read(UC_ARM64_REG_X2);start,end=struct.unpack('<QQ',c.mem_read(ref,16));assert sp<=start<end<=sp+0x10000 and 3<=end-start<=258
  packets.append(bytes(c.mem_read(start,end-start)));assert len(packets)<=10000;ret()
 elif pc==0x5d9680:
  assert c.reg_read(UC_ARM64_REG_X0)==client; final_calls+=1;ret()
 elif not 0x5d6b80<=pc<0x5d6cf8: raise ValueError(f'Unapproved reference call {pc:#x}')
c.hook_add(UC_HOOK_CODE,hook)
def run(lengths,enabled=True):
 global packets,final_calls
 packets=[];final_calls=0
 c.mem_write(client,bytes(0x600));put32(client,0x12345678);c.mem_write(client+0x510,bytes([16 if enabled else 0]));put64(client+0x2b0,entries);put64(client+0x2b8,len(lengths))
 cursor=body; pieces=[]
 for i,n in enumerate(lengths):
  payload=bytes(((k*37+i*19)&255) for k in range(n));pieces.append(payload);c.mem_write(cursor,payload or b'\0');put64(entries+24*i,cursor);put32(entries+24*i+8,n);cursor+=max(1,n)+16
 for reg in range(UC_ARM64_REG_X0,UC_ARM64_REG_X0+29):c.reg_write(reg,0)
 c.reg_write(UC_ARM64_REG_X0,client);c.reg_write(UC_ARM64_REG_SP,sp+0xff00);c.reg_write(UC_ARM64_REG_LR,stop)
 c.emu_start(0x5d6b80,stop,timeout=1000000,count=1000000)
 assert c.reg_read(UC_ARM64_REG_PC)==stop
 expected=[]
 if enabled and lengths:
  for payload in pieces:
   for offset in range(0,len(payload),255):
    chunk=payload[offset:offset+255];expected.append(bytes([0xb3,len(chunk),int(offset==0)])+chunk)
  expected.append(bytes([0xb3,0,0]));assert final_calls==1
 else:assert final_calls==0
 assert packets==expected,(lengths,len(packets),len(expected))
 return packets
cases=[([n],True) for n in range(1026)]+[([n],True) for n in [2048,4096,8192,65536]]+[([1,256,511],True),([0,0,1],True),([],True),([32],False)]
all_packets=[]
for lengths,enabled in cases:all_packets.extend(run(lengths,enabled))
reference=''.join(json.dumps({'sequence':i,'direction':'s2c-system','id':data[0],'length':len(data),'payload':data.hex()},separators=(',',':'))+'\n' for i,data in enumerate(all_packets,1)).encode()
if args.output:
 # Exclusive creation avoids overwriting a caller's capture or another file.
 fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'wb') as f: f.write(reference)
report={'originalInputVerified':True,'moduleID':input_proof['moduleID'],'producer':'0x5d6b80','producerSHA256':producer_hash,'cases':len(cases),'packets':len(all_packets),'payloadBytes':sum(map(len,all_packets)),'chunkMaximum':255,'logicalHeaderBytes':3,'allOriginalOutputsMatched':True,'referenceSHA256':hashlib.sha256(reference).hexdigest(),'osNetworkCalls':0,'gameEntryInvocations':0,'liveServerVerified':False}
print(json.dumps(report,indent=2))
