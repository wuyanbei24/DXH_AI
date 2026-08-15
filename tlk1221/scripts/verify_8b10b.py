#!/usr/bin/env python3
# Corrected 8B10B table verification.
# Encoder case selector = {rd(1), kin(1), din(8)} = 10 bits, but labels are written
# as 11'b... where the MSB (bit10) is the zero-extended redundant bit (always 0).
# So within the 11-char string: idx[0]=redundant MSB, idx[1]=rd, idx[2]=kin, idx[3:10]=din.
import re, sys

def parse_encode(path):
    txt = open(path).read()
    pat = re.compile(r"11'b([01]{11})\s*:\s*begin\s*comb_dout=10'h([0-9A-Fa-f]+);\s*comb_code_err=1'b([01])")
    tab = {}
    bad_msb = 0
    for m in pat.finditer(txt):
        s = m.group(1)
        if s[0] != '0':
            bad_msb += 1
        rd = int(s[1]); kin = int(s[2]); din = int(s[3:11],2)
        code = int(m.group(2),16); cerr = int(m.group(3))
        tab[(rd,kin,din)] = (code, cerr)
    return tab, bad_msb

def parse_decode(path):
    txt = open(path).read()
    pat = re.compile(r"10'h([0-9A-Fa-f]+)\s*:\s*begin\s*comb_dout=8'h([0-9A-Fa-f]+);\s*comb_kout=1'b([01]);\s*comb_code_err=1'b([01])")
    tab = {}
    for m in pat.finditer(txt):
        code = int(m.group(1),16)
        tab[code] = (int(m.group(2),16), int(m.group(3)), int(m.group(4)))
    return tab

enc, bad_msb = parse_encode(r"F:/wc.prj/pulse_mfpga/src/DXH_AI/tlk1221/rtl/encode_8b10b.v")
dec = parse_decode(r"F:/wc.prj/pulse_mfpga/src/DXH_AI/tlk1221/rtl/decode_8b10b.v")
print("Encoder entries:", len(enc), " (labels with MSB!=0:", bad_msb, ")  Decoder entries:", len(dec))

VALID_K_DIN = {0x1C,0x3C,0x5C,0x7C,0x9C,0xBC,0xDC,0xFC,  # K28.0..K28.7
               0xF7,0xFB,0xFD,0xFE}                      # K23.7 K27.7 K29.7 K30.7

ones = lambda x: bin(x).count('1')
rt_fail=0; rt_examples=[]; enc_inj=0; seen_rd_code={}; val_fail=0; val_ex=[]

# 1) Encode injectivity within a fixed rd (code unique per (din,kin))
for (rd,kin,din),(code,cerr) in enc.items():
    k=(rd,code)
    if k in seen_rd_code and seen_rd_code[k]!=(din,kin):
        enc_inj+=1
    else:
        seen_rd_code[k]=(din,kin)

# 2) Round-trip for VALID inputs; and that invalid K -> code_err
for rd in (0,1):
    for kin in (0,1):
        for din in range(256):
            if (rd,kin,din) not in enc:
                # selector with no explicit entry -> default -> code_err=1
                continue
            code,cerr = enc[(rd,kin,din)]
            is_valid_k = (kin==1 and din in VALID_K_DIN)
            if (kin==0) or is_valid_k:
                # must encode successfully and round-trip
                if cerr!=0:
                    rt_fail+=1; rt_examples.append("ENC_ERR rd=%d kin=%d din=%02X cerr=1"%(rd,kin,din))
                    continue
                if code not in dec:
                    rt_fail+=1; rt_examples.append("NO_DEC code=%03X rd=%d din=%02X kin=%d"%(code,rd,din,kin))
                    continue
                dout,kout,dcerr=dec[code]
                if dcerr!=0 or dout!=din or kout!=kin:
                    rt_fail+=1
                    if len(rt_examples)<15: rt_examples.append("RT rd=%d kin=%d din=%02X->%03X->dout=%02X k=%d"%(rd,kin,din,code,dout,kout))
            else:
                # invalid K (kin=1 but din not a valid K din) -> encoder MUST error
                if cerr==0:
                    val_fail+=1
                    if len(val_ex)<10: val_ex.append("INVALID_K_ACCEPTED rd=%d din=%02X->%03X"%(rd,din,code))

print("Encoder injectivity collisions (same rd,code -> diff (din,kin)):", enc_inj)
print("Round-trip failures (valid D/K inputs):", rt_fail)
for e in rt_examples[:15]: print("   ",e)
print("Invalid-K accepted by encoder (should be code_err=1):", val_fail)
for e in val_ex[:10]: print("   ",e)

# 3) K28.5 comma / idle word used in design
for rd in (0,1):
    code,cerr = enc[(rd,1,0xBC)]
    dout,kout,dcerr=dec[code]
    print("K28.5 RD=%d -> %03X (dec-> %02X k=%d)"%(rd,code,dout,kout))

# 4) Sample D codes both polarities
for din in (0x00,0x12,0x16,0x1e,0x2c,0x55):
    c0=enc[(0,0,din)][0]; c1=enc[(1,0,din)][0]
    print("D%02X RD-=%03X RD+=%03X dec(RD-)=%02X dec(RD+)=%02X"%(din,c0,c1,dec[c0][0],dec[c1][0]))
