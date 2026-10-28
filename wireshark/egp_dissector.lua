-- SPDX-License-Identifier: GPL-2.0-or-later
-- EGP (RFC 904) Wireshark Lua dissector, IPv4 protocol number 8.
-- Save into Wireshark's personal plugins directory and restart Wireshark.
local egp = Proto('egp_custom', 'Exterior Gateway Protocol (EGP, RFC 904)')
local types = { [1]='Update (NR)', [2]='Poll', [3]='Acquisition', [5]='Hello / I-H-U', [8]='Error' }
local hello_codes = { [0]='Hello', [1]='I-H-U' }
local acq_codes = { [0]='Request', [1]='Confirm', [2]='Refuse', [3]='Cease', [4]='Cease-ack' }
local status_codes = { [0]='Indeterminate', [1]='Up', [2]='Down' }
local modes = { [0]='Active or passive', [1]='Active only', [2]='Passive only' }
local causes = { [0]='Unspecified', [1]='Active mode', [2]='Passive mode',
  [3]='Insufficient resources', [4]='Administratively prohibited',
  [5]='Going down', [6]='Parameter problem', [7]='Protocol violation' }
local reasons = { [0]='Unspecified', [1]='Bad EGP header format',
  [2]='Bad EGP data field format', [3]='Reachability info unavailable',
  [4]='Excessive polling rate', [5]='No response' }
local f = {
  ver=ProtoField.uint8('egp_custom.version','Version',base.DEC),
  typ=ProtoField.uint8('egp_custom.type','Type',base.DEC,types),
  code=ProtoField.uint8('egp_custom.code','Code',base.DEC),
  status=ProtoField.uint8('egp_custom.status','Status (raw)',base.HEX),
  mode=ProtoField.uint8('egp_custom.mode','Acquisition Mode',base.DEC,modes),
  cause=ProtoField.uint8('egp_custom.cause','Acquisition Cause',base.DEC,causes),
  state=ProtoField.uint8('egp_custom.state','Reachability State',base.DEC,status_codes,0x7f),
  unsolicited=ProtoField.bool('egp_custom.unsolicited','Unsolicited Update / Error',8,nil,0x80),
  checksum=ProtoField.uint16('egp_custom.checksum','Checksum',base.HEX),
  checksum_valid=ProtoField.bool('egp_custom.checksum_valid','Checksum Valid'),
  asn=ProtoField.uint16('egp_custom.asn','Autonomous System',base.DEC),
  seq=ProtoField.uint16('egp_custom.sequence','Sequence Number',base.DEC),
  hello_interval=ProtoField.uint16('egp_custom.hello_interval','Hello Interval (seconds)',base.DEC),
  poll_interval=ProtoField.uint16('egp_custom.poll_interval','Poll Interval (seconds)',base.DEC),
  reserved=ProtoField.uint16('egp_custom.reserved','Reserved',base.HEX),
  srcnet=ProtoField.ipv4('egp_custom.source_network','IP Source Network'),
  internal=ProtoField.uint8('egp_custom.internal_gateways','Internal Gateways',base.DEC),
  external=ProtoField.uint8('egp_custom.external_gateways','External Gateways',base.DEC),
  gateway=ProtoField.bytes('egp_custom.gateway_host','Gateway Host Bytes'),
  distance_count=ProtoField.uint8('egp_custom.distance_count','Distance Groups',base.DEC),
  distance=ProtoField.uint8('egp_custom.distance','Distance',base.DEC),
  net_count=ProtoField.uint8('egp_custom.net_count','Number of Networks',base.DEC),
  network=ProtoField.bytes('egp_custom.network','Network Number (classful bytes)'),
  error_reason=ProtoField.uint16('egp_custom.error_reason','Error Reason',base.DEC,reasons),
  bad_header=ProtoField.bytes('egp_custom.bad_header','Offending EGP Header'),
  trailing=ProtoField.bytes('egp_custom.trailing','Trailing / Padding Bytes'),
  warning=ProtoField.string('egp_custom.warning','Parse Note'),
}
egp.fields = f
local malformed=ProtoExpert.new('egp_custom.malformed','Malformed EGP message',expert.group.MALFORMED,expert.severity.ERROR)
local bad_checksum=ProtoExpert.new('egp_custom.bad_checksum','Bad EGP checksum',expert.group.CHECKSUM,expert.severity.WARN)
egp.experts={malformed,bad_checksum}
local function note(t,msg)
  t:add(f.warning,msg)
  t:add_proto_expert_info(malformed,msg)
end
local function valid_checksum(tvb)
  local sum, len = 0, tvb:len()
  for i=0,len-2,2 do sum=sum+tvb(i,2):uint() end
  if len%2==1 then sum=sum+tvb(len-1,1):uint()*256 end
  while sum>65535 do sum=sum%65536+math.floor(sum/65536) end
  return sum==65535
end
local function net_width(first)
  if first < 128 then return 1 elseif first < 192 then return 2 elseif first < 224 then return 3 end
  return nil
end
local function field_if(t, tvb, offset, width, fld)
  if offset+width <= tvb:len() then t:add(fld,tvb(offset,width)); return true end
  return false
end
function egp.dissector(tvb,pinfo,tree)
  local len=tvb:len()
  pinfo.cols.protocol='EGP'
  local t=tree:add(egp,tvb(), 'Exterior Gateway Protocol (EGP)')
  if len < 10 then
    note(t,'Truncated: EGP requires at least 10 bytes')
    if len > 0 then t:add(f.trailing,tvb()) end
    pinfo.cols.info='EGP (truncated)'
    return len
  end
  t:add(f.ver,tvb(0,1)); t:add(f.typ,tvb(1,1))
  local typ,code=tvb(1,1):uint(),tvb(2,1):uint()
  local code_item=t:add(f.code,tvb(2,1))
  local name=types[typ] or ('Unknown type '..typ)
  if typ==5 then name=hello_codes[code] or name; code_item:append_text(' ('..(hello_codes[code] or 'Unknown')..')') end
  if typ==3 then name=acq_codes[code] or name; code_item:append_text(' ('..(acq_codes[code] or 'Unknown')..')') end
  t:add(f.status,tvb(3,1)); t:add(f.checksum,tvb(4,2))
  if typ==3 then
    t:add(code<=1 and f.mode or f.cause,tvb(3,1))
  else
    t:add(f.state,tvb(3,1))
    if typ==1 or typ==8 then t:add(f.unsolicited,tvb(3,1)) end
  end
  if tvb:reported_len()>len then
    note(t,'Capture truncated: checksum not checked')
  else
    local valid=valid_checksum(tvb)
    t:add(f.checksum_valid,valid):set_generated()
    if not valid then t:add_proto_expert_info(bad_checksum) end
  end
  if tvb(0,1):uint()~=2 then t:add(f.warning,'Unsupported EGP version (expected 2)') end
  t:add(f.asn,tvb(6,2)); t:add(f.seq,tvb(8,2))
  local seq=tvb(8,2):uint()
  pinfo.cols.info=string.format('%s, AS %u, Seq %u',name,tvb(6,2):uint(),seq)
  local off=10
  if typ==3 and (code==0 or code==1) then
    if field_if(t,tvb,off,2,f.hello_interval) then off=off+2 else note(t,'Truncated Hello Interval') end
    if field_if(t,tvb,off,2,f.poll_interval) then off=off+2 else note(t,'Truncated Poll Interval') end
  elseif typ==2 then
    if field_if(t,tvb,off,2,f.reserved) then off=off+2 else note(t,'Truncated reserved field') end
    if field_if(t,tvb,off,4,f.srcnet) then off=off+4 else note(t,'Truncated IP Source Network') end
  elseif typ==1 then
    if len<16 then
      note(t,'Truncated Update fixed header')
    else
      local nint,nex=tvb(10,1):uint(),tvb(11,1):uint()
      t:add(f.internal,tvb(10,1)); t:add(f.external,tvb(11,1))
      t:add(f.srcnet,tvb(12,4)); off=16
      local nw=net_width(tvb(12,1):uint())
      if not nw then
        note(t,'Unsupported source network class for gateway address decoding')
      else
        local host_width=4-nw
        local ok=true
        for g=1,nint+nex do
          if not ok then break end
          if off+host_width+1>len then note(t,'Truncated gateway entry '..g); break end
          local kind=g<=nint and 'Internal' or 'External'
          local gw=t:add(egp,tvb(off,host_width+1),kind..' Gateway '..g)
          gw:add(f.gateway,tvb(off,host_width)); off=off+host_width
          local nd=tvb(off,1):uint(); gw:add(f.distance_count,tvb(off,1)); off=off+1
          for d=1,nd do
            if off+2>len then note(gw,'Truncated distance group');ok=false;break end
            local distance=tvb(off,1):uint(); local nn=tvb(off+1,1):uint()
            local disttree=gw:add(egp,tvb(off,2),'Distance '..distance..' ('..nn..' networks)')
            if distance==255 then disttree:append_text(' - Unreachable') end
            disttree:add(f.distance,tvb(off,1)); disttree:add(f.net_count,tvb(off+1,1));off=off+2
            for n=1,nn do
              if off>=len then note(disttree,'Truncated network number');ok=false;break end
              local w=net_width(tvb(off,1):uint())
              if not w then note(disttree,'Invalid classful network prefix');ok=false;break end
              if off+w>len then note(disttree,'Truncated network number');ok=false;break end
              local nr=tvb(off,w)
              local octets={tvb(off,1):uint(),0,0,0}
              for i=2,w do octets[i]=tvb(off+i-1,1):uint() end
              disttree:add(f.network,nr):append_text(string.format(' (%d.%d.%d.%d)',octets[1],octets[2],octets[3],octets[4]))
              off=off+w
            end
            if not ok then break end
          end
        end
      end
    end
  elseif typ==8 then
    if field_if(t,tvb,off,2,f.error_reason) then off=off+2 else note(t,'Truncated Error reason') end
    if len<24 then note(t,'Truncated Error: requires reason and 12 quoted header bytes') end
    if off<len then
      local n=math.min(12,len-off)
      t:add(f.bad_header,tvb(off,n));off=off+n
    end
  end
  if off<len then t:add(f.trailing,tvb(off,len-off)):append_text(' (may include padding or unrecognized data)') end
  return len
end
-- IPv4 protocol 8 = EGP (not a TCP/UDP port).
DissectorTable.get('ip.proto'):add(8,egp)
