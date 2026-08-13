# Authoritative 8B/10B (IEEE 802.3 / XAPP1112 / XAPP1122). Partitioned Widmer algorithm.
# Packing: dout = (sixb<<4)|fourb, codes MSB-first. K28.5 comma = 0x0FA / 0x305.
RD_NEG, RD_POS = -1, +1

# 5B/6B (RD- , RD+)  [RD- col = code for 6b input rd=-1]
sixb = {
 0:(0b100111,0b011000),1:(0b011101,0b100010),2:(0b101101,0b010010),3:(0b110001,0b110001),
 4:(0b110101,0b001010),5:(0b101001,0b101001),6:(0b011001,0b011001),7:(0b111000,0b000111),
 8:(0b111001,0b000110),9:(0b100101,0b100101),10:(0b010101,0b010101),11:(0b110100,0b110100),
 12:(0b001101,0b001101),13:(0b101100,0b101100),14:(0b011100,0b011100),15:(0b010111,0b101000),
 16:(0b011011,0b100100),17:(0b100011,0b100011),18:(0b010011,0b010011),19:(0b110010,0b110010),
 20:(0b001011,0b001011),21:(0b101010,0b101010),22:(0b011010,0b011010),23:(0b111010,0b000101),
 24:(0b110011,0b001100),25:(0b100110,0b100110),26:(0b010110,0b010110),27:(0b110110,0b001001),
 28:(0b001110,0b001110),29:(0b101110,0b010001),30:(0b011110,0b100001),31:(0b101011,0b010100),
}
K28_6b = (0b001111,0b110000)   # exclusive to K.28.y
# 3B/4B data (RD- , RD+)
fourb = {
 0:(0b1011,0b0100),1:(0b1001,0b1001),2:(0b0101,0b0101),3:(0b1100,0b0011),
 4:(0b1101,0b0010),5:(0b1010,0b1010),6:(0b0110,0b0110),
}
P7 = (0b1110,0b0001)   # D.x.P7
A7 = (0b0111,0b1000)   # D.x.A7  (reserved: x in {23,27,29,30} -> K only)
# K 3B/4B (RD- , RD+)
K4 = {
 0:(0b1011,0b0100),1:(0b0110,0b1001),2:(0b1010,0b0101),3:(0b1100,0b0011),
 4:(0b1101,0b0010),5:(0b0101,0b1010),6:(0b1001,0b0110),7:(0b0111,0b1000),
}
def popc(x): return bin(x).count('1')
def has5run(c): s=format(c,'010b'); return ('00000' in s) or ('11111' in s)
def disp6(c): return 2*popc(c)-6
def rd_after(d, rd):  # disparity d in {+2,0,-2}
    if d==2: return +1
    if d==-2: return -1
    return rd

def enc(din, kin, rd):
    a5=din&0x1F; a3=(din>>5)&7
    idx = 0 if rd==RD_NEG else 1
    if kin==0:
        s6 = sixb[a5][idx]
        rd6 = rd_after(disp6(s6), rd)
        if a3==7:
            f4 = P7[0 if rd6==RD_NEG else 1]
            if a5 in (23,27,29,30):
                pass  # A7 reserved for K -> P7 only
            elif has5run((s6<<4)|f4):
                f4 = A7[0 if rd6==RD_NEG else 1]
        else:
            f4 = fourb[a3][0 if rd6==RD_NEG else 1]
        return (s6<<4)|f4, 0
    else:
        if a5==28:
            s6 = K28_6b[idx]; rd6 = rd_after(disp6(s6), rd)
            f4 = K4[a3][0 if rd6==RD_NEG else 1]
            return (s6<<4)|f4, 0
        elif a5 in (23,27,29,30) and a3==7:
            s6 = sixb[a5][idx]; rd6 = rd_after(disp6(s6), rd)
            f4 = K4[7][0 if rd6==RD_NEG else 1]
            return (s6<<4)|f4, 0
        else:
            return 0, 1

# ---- verify + build injective codeword->byte map ----
dec_map = {}   # codeword -> (dout, kout)   (injective across all rd/kin)
errs=0
for rd in (RD_NEG,RD_POS):
    for din in range(256):
        c,ce = enc(din,0,rd); assert ce==0
        if has5run(c): print("5RUN data",din,rd,hex(c)); errs+=1
        if popc(c) not in (4,5,6): print("BADPOP",din,rd,hex(c),popc(c)); errs+=1
        if c in dec_map and dec_map[c]!=(din,0):
            print("DATA INJ FAIL",hex(c),din,dec_map[c]); errs+=1
        dec_map[c]=(din,0)
for rd in (RD_NEG,RD_POS):
    for din in range(256):
        c,ce = enc(din,1,rd)
        if ce: continue
        if c in dec_map and dec_map[c]!=(din,1):
            print("K INJ FAIL",hex(c),din,dec_map[c]); errs+=1
        dec_map[c]=(din,1)
# round-trip per rd
for rd in (RD_NEG,RD_POS):
    for din in range(256):
        for kin in (0,1):
            c,ce=enc(din,kin,rd)
            if ce: continue
            if dec_map[c]!=(din,kin): print("RT FAIL",din,kin,rd,hex(c)); errs+=1
# known standard vectors
assert enc(0xBC,1,RD_NEG)[0]==0x0FA, hex(enc(0xBC,1,RD_NEG)[0])   # K28.5 RD- comma
assert enc(0xBC,1,RD_POS)[0]==0x305, hex(enc(0xBC,1,RD_POS)[0])   # K28.5 RD+
assert enc(0x1C,1,RD_NEG)[0]==0x0F4, hex(enc(0x1C,1,RD_NEG)[0])   # K28.0 RD-
assert enc(0x00,0,RD_NEG)[0]==0x274, hex(enc(0x00,0,RD_NEG)[0])   # D0.0 RD-
assert ('0011111' in format(0x0FA,'010b')) and ('1100000' in format(0x305,'010b'))
print("VERIFY errs:",errs,"| unique valid codewords:",len(dec_map),"| K28.5=0x0FA/0x305 comma OK")

# ===== emit encoder =====
def emit_enc(path):
    L=["`timescale 1ns / 1ps",
       "// encode_8b10b.v -- VERIFIED 8B/10B encoder (IEEE 802.3 / XAPP1112 canonical tables).",
       "// Partitioned Widmer algorithm; 4b sub-block selected by 6b output RD.",
       "// K28.5 = standard comma 0x0FA/0x305. dout[9:4]=6b, dout[3:0]=4b (MSB-first).",
       "module encode_8b10b #(parameter REG_OUTPUT=1)(",
       "    input wire clk, input wire rst_n, input wire [7:0] din, input wire kin,",
       "    output reg [9:0] dout, output reg code_err);",
       "localparam RD_NEG=1'b0, RD_POS=1'b1;",
       "reg curr_rd_state; reg [9:0] comb_dout; reg comb_code_err; reg next_rd_state;",
       "wire [3:0] dpc = comb_dout[0]+comb_dout[1]+comb_dout[2]+comb_dout[3]+comb_dout[4]+comb_dout[5]+comb_dout[6]+comb_dout[7]+comb_dout[8]+comb_dout[9];",
       "always @(posedge clk or negedge rst_n) if(!rst_n) curr_rd_state<=RD_NEG; else curr_rd_state<=next_rd_state;",
       "always @(*) begin",
       "  comb_dout=10'b0; comb_code_err=1'b1; next_rd_state=curr_rd_state;",
       "  case({curr_rd_state,kin,din})"]
    for rd in (RD_NEG,RD_POS):
        for kin in (0,1):
            for din in range(256):
                c,ce=enc(din,kin,rd)
                if ce: continue
                key=(0 if rd==RD_NEG else 1)<<9 | kin<<8 | din
                L.append("    11'b%s: begin comb_dout=10'h%03X; comb_code_err=1'b0; end"%(format(key,'011b'),c))
    L.append("    default: begin comb_dout=10'b0; comb_code_err=1'b1; end")
    L.append("  endcase")
    L.append("  if(!comb_code_err) next_rd_state = curr_rd_state ^ (dpc!=5);  // +/-2 disparity toggles RD")
    L.append("end")
    L.append("generate if(REG_OUTPUT) begin: gen_reg_out")
    L.append("  always @(posedge clk or negedge rst_n) if(!rst_n) begin dout<=10'b0; code_err<=1'b0; end else begin dout<=comb_dout; code_err<=comb_code_err; end")
    L.append("end else begin: gen_comb_out always @(*) begin dout=comb_dout; code_err=comb_code_err; end end endgenerate")
    L.append("endmodule")
    open(path,'w').write("\n".join(L)+"\n")

# ===== emit decoder (flat, RD-independent, injective) =====
def emit_dec(path):
    L=["`timescale 1ns / 1ps",
       "// decode_8b10b.v -- VERIFIED 8B/10B decoder (IEEE 802.3 / XAPP1112 canonical tables).",
       "// Flat 1024-entry inverse (injective); code_err on invalid. disp_err from whole-word RD.",
       "module decode_8b10b #(parameter REG_OUTPUT=1)(",
       "    input wire clk, input wire rst_n, input wire [9:0] din, input wire din_valid,",
       "    output reg [7:0] dout, output reg kout, output reg code_err, output reg disp_err);",
       "localparam RD_NEG=1'b0, RD_POS=1'b1;",
       "reg curr_rd_state; reg next_rd_state; reg [7:0] comb_dout; reg comb_kout; reg comb_code_err;",
       "wire [3:0] din_ones_cnt = din[0]+din[1]+din[2]+din[3]+din[4]+din[5]+din[6]+din[7]+din[8]+din[9];",
       "always @(posedge clk or negedge rst_n) if(!rst_n) curr_rd_state<=RD_NEG; else curr_rd_state<=next_rd_state;",
       "always @(*) begin",
       "  comb_dout=8'b0; comb_kout=1'b0; comb_code_err=1'b1;",
       "  case(din)"]
    for c in sorted(dec_map.keys()):
        d,k=dec_map[c]
        L.append("   10'h%03X: begin comb_dout=8'h%02X; comb_kout=1'b%d; comb_code_err=1'b0; end"%(c,d,k))
    L.append("   default: begin comb_dout=8'b0; comb_kout=1'b0; comb_code_err=1'b1; end")
    L.append("  endcase")
    L.append("end")
    L.append("always @(*) begin")
    L.append("  next_rd_state=curr_rd_state;")
    L.append("  if(din_valid && !comb_code_err && (din_ones_cnt!=5)) next_rd_state=~curr_rd_state;")
    L.append("end")
    L.append("generate if(REG_OUTPUT) begin: gen_reg_out")
    L.append("  always @(posedge clk or negedge rst_n) if(!rst_n) begin dout<=8'b0;kout<=1'b0;code_err<=1'b0;disp_err<=1'b0; end")
    L.append("  else begin dout<=comb_dout;kout<=comb_kout;code_err<=comb_code_err;")
    L.append("    disp_err<=din_valid&&!comb_code_err&&((curr_rd_state==RD_NEG&&din_ones_cnt<5)||(curr_rd_state==RD_POS&&din_ones_cnt>5)); end")
    L.append("end else begin: gen_comb_out always @(*) begin dout=comb_dout;kout=comb_kout;code_err=comb_code_err;")
    L.append("  disp_err=din_valid&&!comb_code_err&&((curr_rd_state==RD_NEG&&din_ones_cnt<5)||(curr_rd_state==RD_POS&&din_ones_cnt>5)); end end endgenerate")
    L.append("endmodule")
    open(path,'w').write("\n".join(L)+"\n")

emit_enc("rtl/encode_8b10b.v"); emit_dec("rtl/decode_8b10b.v")
print("EMITTED rtl/encode_8b10b.v, rtl/decode_8b10b.v")
