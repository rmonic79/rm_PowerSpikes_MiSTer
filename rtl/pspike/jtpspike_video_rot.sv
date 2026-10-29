// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of rmPowerSpikes_MiSTer.
    Author: Umberto Parisi (rmonic79)

    jtpspike_video_rot.sv — CRT Rotate per i giochi verticali del core di
    Andrea Bogazzi (Turbo Force, Aero Fighters, Sonic Wings: MAME ROT270).
    Il gioco esce GIA' GIRATO di 90 gradi su un CRT orizzontale, a 15 kHz,
    senza quadro in memoria: ogni riga del tubo e' fatta dalle colonne del
    gioco, calcolate qui per colonne invece che per righe (doc 22 di
    MiSTer_Discovery_Docs, adattato a un core con la grafica in SDRAM).

    IL QUADRO NATIVO. Il renderer di Andrea (jtpspike_video) resta com'e' e
    resta il riferimento: qui si rifanno gli stessi conti per pixel, cioe' per
    il pixel (x, y) dello schermo normale (x colonna 0..W-1, y riga 0..Hr-1,
    flip della scheda compreso) si ricavano gli stessi indirizzi di mappa e di
    line buffer che usa lui. Le formule sono ricavate dai suoi moduli
    (jtpspike_scr + jtframe_scroll, jtpspike_obj + objscan + jtframe_draw) e
    sono commentate dove servono; il banco confronta colonna per colonna.

    IL RASTER D'USCITA. Stessa riga del gioco (456 x 8 = 3.648 colpi), pixel a
    57,27 / 6 = 9,545 MHz, 608 per riga: ohcnt torna a zero nello stesso colpo
    di H. Stesso numero di righe del quadro del gioco (256 Turbo Force, 250
    Aero Fighters), quindi stessi 15,70 kHz e stessa frequenza di quadro. Il
    VSync d'uscita sta alla riga 0 del gioco, la prima riga visibile 16 righe
    dopo, l'ultima 7 righe prima del VSync dopo (come rmTSamurai): righe
    visibili N = righe del quadro - 23 (233 / 227).

    LA FUSIONE. Le W colonne del gioco (352 / 320) vanno nelle N righe: ogni
    riga copre W/N colonne (1,51 / 1,41) e prende le 2 o 3 colonne su cui cade,
    ciascuna pesata per quanto ne copre, mescolate in luce (quadrati, somma
    pesata, radice), come fa il tubo quando stringe la geometria. Nessuna
    colonna si perde. In unita' di 1/N di colonna la riga l copre [l*W,
    (l+1)*W): tutto intero, niente arrotondamenti nei pesi.

    IL TAGLIO (scelta dell OSD, al posto della fusione). Ogni riga e' una
    colonna sola, 1:1 come su rmTSamurai: si vedono N colonne su W, e la
    finestra si sposta a scatti di 8 colonne (zero = centrata). Niente
    scintillio della fusione, ma le colonne fuori finestra non si vedono.

    IL LAVORO. Le colonne si calcolano a strisce di 16 (una parola della ROM
    contiene 8 pixel affiancati, quindi una lettura serve piu' colonne):
    sfondo (2 strati) e sprite (2 chip) in parallelo, ognuno sul suo slot
    SDRAM, in quattro buffer di striscia; poi la composizione con le priorita'
    del mixer di Andrea scrive l'indice di palette in un anello di 64 colonne.
    L'uscita legge dall'anello: il calcolo puo' stare fino a 4 strisce avanti
    all'uscita, cosi' un punto pieno di sprite si spalma sulle strisce vicine.
    Una colonna non ancora pronta esce nera (e il banco lo conta).

    IL GIOCO resta sul suo VBlank: si commuta solo il video, a fine quadro.
*/

`timescale 1ns / 1ps

// =========================================================================
// RAM a doppia porta semplice (una scrittura, una lettura registrata)
// =========================================================================
module jtpspike_rot_ram #(parameter DW=8, AW=12)(
	input               clk,
	input               we,
	input      [AW-1:0] waddr,
	input      [DW-1:0] wdata,
	input      [AW-1:0] raddr,
	output reg [DW-1:0] q
);
	reg [DW-1:0] mem[0:(1<<AW)-1];
	always @(posedge clk) begin
		if (we) mem[waddr] <= wdata;
		q <= mem[raddr];
	end
endmodule

// =========================================================================
// Strato di tile per una striscia di 16 colonne.
//
// Il pixel (x, y) dello strato, dai conti di jtframe_scroll in jtpspike_scr
// con le pipeline del tilemap (8 pixel dietro il fetch) e del colmix:
//   senza flip  mx = x + kx,  my = y + ky
//   con flip    mx = kx - x,  my = ky - y
// (kx, ky calcolati in jtpspike_video_rot). Nel tile il pixel e' sempre il
// nibble mx[2:0] della parola: col flip il tilemap scorre all'indietro e
// rovescia anche l'ordine nel tile, le due cose si annullano.
// =========================================================================
module jtpspike_rot_tile(
	input             rst,
	input             clk,
	input             start,
	output reg        busy,
	input      [ 8:0] x0,
	input      [ 7:0] rows,
	input             flip,
	input      [ 8:0] kx, ky,
	input             layer,
	input      [31:0] gfxbank,

	output reg [11:0] vram_addr,
	input      [15:0] vram_data,
	output reg [17:0] rom_addr,     // {codice, riga del tile}
	output reg        rom_cs,
	input      [31:0] rom_data,
	input             rom_ok,

	output reg        we,
	output reg [11:0] waddr,        // {colonna 0..15, riga}
	output reg [ 6:0] wdata         // {palette, pixel}
);

localparam [2:0] S_IDLE=3'd0, S_ROW=3'd1, S_COL=3'd2, S_V1=3'd3, S_V2=3'd4, S_ROM=3'd5;

reg  [ 2:0] st;
reg  [ 7:0] y;
reg  [ 3:0] c;
reg  [ 8:0] my;
reg  [ 5:0] key;
reg         key_v;
reg  [31:0] word;
reg  [ 2:0] pal;

wire [ 8:0] xc     = x0 + {5'd0, c};
wire [ 8:0] mx     = flip ? (kx - xc) : (xc + kx);
wire [ 8:0] my_now = flip ? (ky - {1'b0, y}) : ({1'b0, y} + ky);
// turbofrc/aerofgt: banco = gfxbank[{strato, codice[12:11]}], 4 bit
wire [ 2:0] bsel   = {layer, vram_data[12:11]};
wire [ 3:0] bank   = gfxbank[{bsel, 2'b00} +: 4];
wire [ 3:0] pix    = word[{mx[2:0], 2'b00} +: 4];

always @(posedge clk) begin
	we <= 1'b0;
	if (rst) begin
		st     <= S_IDLE;
		busy   <= 1'b0;
		rom_cs <= 1'b0;
	end else case (st)
	S_IDLE: if (start) begin
		y      <= 8'd0;
		busy   <= 1'b1;
		st     <= S_ROW;
	end
	S_ROW: if (y == rows) begin
		busy   <= 1'b0;
		st     <= S_IDLE;
	end else begin
		my    <= my_now;
		c     <= 4'd0;
		key_v <= 1'b0;
		st    <= S_COL;
	end
	S_COL: if (key_v && (mx[8:3] == key)) begin
		we    <= 1'b1;
		waddr <= {c, y};
		wdata <= {pal, pix};
		if (c == 4'd15) begin
			y  <= y + 8'd1;
			st <= S_ROW;
		end else c <= c + 4'd1;
	end else begin
		key       <= mx[8:3];
		vram_addr <= {my[8:3], mx[8:3]};
		st        <= S_V1;
	end
	S_V1: st <= S_V2;                                   // la VRAM risponde al colpo dopo
	// La richiesta (rom_cs) sale insieme all indirizzo vero e scende col dato:
	// con cs alto su un indirizzo vecchio jtframe_romrq partirebbe a leggerlo, e
	// cambiare indirizzo durante l attesa mette in cache il dato sbagliato.
	S_V2: begin
		pal      <= vram_data[15:13];
		rom_addr <= {bank, vram_data[10:0], my[2:0]};
		rom_cs   <= 1'b1;
		st       <= S_ROM;
	end
	// data_ok di jtframe_romrq_bcache e' combinatorio sull indirizzo: vale 1
	// solo se l indirizzo presente e' in cache da un colpo, quindi qui il dato
	// e' sempre quello giusto. L indirizzo resta fermo finche' non arriva.
	S_ROM: if (rom_ok) begin
		word   <= rom_data;
		key_v  <= 1'b1;
		rom_cs <= 1'b0;
		st     <= S_COL;
	end
	default: st <= S_IDLE;
	endcase
end

endmodule

// =========================================================================
// Un chip sprite (VS8904/VS8905) per una striscia di 16 colonne.
//
// La lista e l ordine sono quelli di jtpspike_objscan: puntatore alla parola
// 0x1FE, slot dal primo a 0x1F8, prima la passata pri==0 poi pri==1, l ultimo
// pixel opaco scritto vince (line buffer keep-last di jtframe_obj_buffer).
//
// VERTICALE. Lo sprite copre le righe vr = v0 .. v0+blk_h-1 (mod 512), con
//   v0 = oy + yoffs, blk_h = ((ysize+1)*zy) >> 1, vr = y senza flip e
//   vr = vsize-1-y col flip; riga sorgente src = (dy*recip) >> 8, dy = vr-v0.
// ORIZZONTALE. jtframe_draw con lo zoom: a ogni colpo scrive il pixel
//   sorgente k all indirizzo xpos + m_k e poi avanza; m_0 = 0 e per k >= 1
//   m_k = floor((64(k-1) + 127) / hz). All indirizzo xpos + d finiscono quindi
//   i pixel k_lo(d)..k_hi(d) (uno o due), e resta l ultimo opaco:
//     d = 0: k = 0;  d = 1: k_lo = 1;  d >= 2: k_lo = 1 + ((d*hz - 64) >> 6)
//     d >= 1: k_hi = 1 + ((d*hz + hz - 128) >> 6)
// Il line buffer si legge, per la colonna x, all indirizzo
//   senza flip  A = x + ax,   con flip  A = ax - x   (ax da jtpspike_video_rot)
// SCRITTE: i posti marcati in hud si disegnano spostati nel line buffer di
// sh_lo / sh_mid / sh_hi secondo la colonna mostrata del loro primo indirizzo
// (< zlo, >= zhi, in mezzo); gli altri restano dove sono.
// =========================================================================
module jtpspike_rot_obj(
	input             rst,
	input             clk,
	input             start,
	output reg        busy,
	input      [ 8:0] x0,
	input      [ 8:0] vsize,
	input             flip,
	input      [ 8:0] ax,
	input      [ 8:0] yoffs,
	input      [14:0] cmask,
	input     [127:0] hud,          // posti sprite da spostare (scritte)
	input      [ 8:0] sh_lo, sh_mid, sh_hi, zlo, zhi,

	output reg [ 9:1] objr_addr,
	input      [15:0] objr_dout,
	output reg [15:1] objl_addr,
	input      [15:0] objl_dout,
	output reg [19:0] rom_addr,     // {codice, riga, meta'}
	output reg        rom_cs,
	input      [31:0] rom_data,
	input             rom_ok,

	output reg        we,
	output reg [11:0] waddr,        // {colonna 0..15, riga}
	output reg [ 8:0] wdata,        // {pri, colore, pixel}
	output reg [15:0] cnt_spr       // sprite disegnati nella striscia (banco)
);

localparam [8:0] LAST = 9'h1f8, PTR = 9'h1fe;

// ---------------- la lista ----------------
localparam [3:0] W_IDLE=4'd0, W_PTR=4'd1, W_PTR2=4'd2, W_PTR3=4'd3,
                 W_RD=4'd4, W_EVAL=4'd5, W_TAB=4'd6, W_DRAW=4'd7, W_NEXT=4'd8;

reg  [ 3:0] wst;
reg  [ 8:0] first, slot;
reg         pass;
reg  [ 2:0] rcnt;            // letture in volo delle 4 parole
reg  [15:0] w0, w1, w2, w3;

reg  [ 8:0] oxr, osh;             // posizione nel line buffer, con lo scarto delle scritte
wire [ 8:0] oy     = w0[8:0];
wire [ 8:0] ox     = oxr;
wire [ 8:0] xcol   = flip ? (ax - w1[8:0]) : (w1[8:0] - ax);   // colonna mostrata
wire [ 2:0] xsize  = w2[10:8];
wire [ 2:0] ysize  = w2[14:12];
wire        s_en   = w2[7];
wire        s_pri  = w2[4];
wire        s_fx   = w2[11];
wire        s_fy   = w2[15];
wire [ 5:0] zy     = 6'd32 - {2'd0, w0[15:12]};
wire [ 5:0] zx     = 6'd32 - {2'd0, w1[15:12]};
wire [ 9:0] blk_h  = (({7'd0, ysize} + 10'd1) * {4'd0, zy}) >> 1;
wire [ 7:0] kmax   = {1'b0, xsize, 4'hf};            // K-1 = 16(xsize+1)-1
wire [ 8:0] v0     = oy + yoffs;

reg [8:0] recip_w;
always @* begin
	case (zy)
		6'd17: recip_w = 9'd482; 6'd18: recip_w = 9'd455;
		6'd19: recip_w = 9'd431; 6'd20: recip_w = 9'd410;
		6'd21: recip_w = 9'd390; 6'd22: recip_w = 9'd372;
		6'd23: recip_w = 9'd356; 6'd24: recip_w = 9'd341;
		6'd25: recip_w = 9'd328; 6'd26: recip_w = 9'd315;
		6'd27: recip_w = 9'd303; 6'd28: recip_w = 9'd293;
		6'd29: recip_w = 9'd282; 6'd30: recip_w = 9'd273;
		6'd31: recip_w = 9'd264; default: recip_w = 9'd256;
	endcase
end
reg [6:0] hz_w;
always @* begin
	case (zx)
		6'd17: hz_w = 7'd120; 6'd18: hz_w = 7'd114;
		6'd19: hz_w = 7'd108; 6'd20: hz_w = 7'd102;
		6'd21: hz_w = 7'd98;  6'd22: hz_w = 7'd93;
		6'd23: hz_w = 7'd89;  6'd24: hz_w = 7'd85;
		6'd25: hz_w = 7'd82;  6'd26: hz_w = 7'd79;
		6'd27: hz_w = 7'd76;  6'd28: hz_w = 7'd73;
		6'd29: hz_w = 7'd71;  6'd30: hz_w = 7'd68;
		6'd31: hz_w = 7'd66;  default: hz_w = 7'd64;
	endcase
end

// Indirizzi di line buffer della striscia: senza flip crescono con la
// colonna, col flip calano. a_first (colonna 0) si registra all avvio della
// striscia; a_lo = il piu' basso dei 16.
reg  [ 8:0] a_first;
wire [ 8:0] a_lo    = flip ? (a_first - 9'd15) : a_first;
// La striscia tocca lo sprite (largo al massimo K = kmax+1 indirizzi)?
wire [ 8:0] d_lo    = a_lo - ox;                              // mod 512
wire [ 8:0] d_neg   = ox - a_lo;
wire        hit_x   = (d_lo <= {1'b0, kmax}) || (d_neg < 9'd16);
// Righe visibili: dy in [dy_a, dy_b)
wire        v_in    = (v0 < vsize);
wire [ 9:0] v_end   = {1'b0, v0} + blk_h;
wire        hit_y   = v_in || (v_end > 10'd512);
wire [ 9:0] dy_a_w  = v_in ? 10'd0 : (10'd512 - {1'b0, v0});
wire [ 9:0] dy_lim  = v_in ? ({1'b0, vsize} - {1'b0, v0}) : (10'd512 - {1'b0, v0} + {1'b0, vsize});
wire [ 9:0] dy_b_w  = (dy_lim < blk_h) ? dy_lim : blk_h;

// ---------------- tabella delle colonne ----------------
// Per colonna c: coperta, k_lo, k_hi (k <= 127). Una colonna per colpo, in
// tre stadi registrati (differenza, moltiplicazione, k_lo/k_hi): tutta la
// catena in un colpo non stava nei 17,5 ns (build del 29/10: -0,701 ns).
reg         t_cov [0:15];
reg  [ 6:0] t_klo [0:15];
reg  [ 6:0] t_khi [0:15];
reg  [ 4:0] tc;                    // colonna emessa (0..15), poi 16..18 coda
reg  [ 6:0] hz;
reg  [ 7:0] km;
reg         fx, fy, s_prir;
reg  [ 3:0] colr;
reg  [ 2:0] xs, ys;
reg  [15:0] mapr;
reg  [ 8:0] recip, v0r;
reg  [ 9:0] dy_a, dy_b;

wire [ 3:0] tcc    = tc[3:0];
wire [ 8:0] a_c    = flip ? (a_first - {5'd0, tcc}) : (a_first + {5'd0, tcc});
// stadio 1: d = indirizzo - xpos;  stadio 2: d*hz;  stadio 3: scrittura
reg         s1_v, s2_v;
reg  [ 3:0] s1_c, s2_c;
reg  [ 8:0] s1_d, s2_d;
reg  [13:0] s2_dhz;
wire [14:0] lo_s   = {1'b0, s2_dhz} - 15'd64;
wire [14:0] hi_s   = {1'b0, s2_dhz} + {8'd0, hz} - 15'd128;
wire [ 8:0] klo_c  = (s2_d == 9'd0) ? 9'd0 : (s2_d == 9'd1) ? 9'd1 : (9'd1 + lo_s[14:6]);
wire [ 8:0] khi_r  = (s2_d == 9'd0) ? 9'd0 : (9'd1 + hi_s[14:6]);
wire [ 8:0] khi_c  = (khi_r > {1'b0, km}) ? {1'b0, km} : khi_r;
wire        cov_c  = (s2_d[8:7] == 2'b00) && (klo_c <= {1'b0, km});

// ---------------- disegno: righe ----------------
// Ordine delle colonne: k crescente (senza flip c crescente, col flip
// decrescente). Le parole di una riga vanno da j_first a j_last (j = k>>3).
reg  [ 4:0] c_first;              // prima colonna coperta nell ordine
reg  [ 6:0] k_first, k_last;

// prima e ultima colonna coperta, nell ordine di k (combinatorio sulla tabella)
reg  [4:0] c_first_w, c_last_w;
reg        cov_any;
integer    n;
always @* begin
	cov_any   = 1'b0;
	c_first_w = 5'd0;
	c_last_w  = 5'd0;
	if (!flip) begin
		for (n = 15; n >= 0; n = n - 1) if (t_cov[n]) begin c_first_w = n[4:0]; cov_any = 1'b1; end
		for (n = 0; n < 16; n = n + 1)  if (t_cov[n]) c_last_w = n[4:0];
	end else begin
		for (n = 0; n < 16; n = n + 1)  if (t_cov[n]) begin c_first_w = n[4:0]; cov_any = 1'b1; end
		for (n = 15; n >= 0; n = n - 1) if (t_cov[n]) c_last_w = n[4:0];
	end
end

// fetcher
localparam [2:0] F_IDLE=3'd0, F_ROW=3'd1, F_LUT=3'd2, F_LUT2=3'd3, F_LUT3=3'd4, F_ROM=3'd5, F_PUSH=3'd6, F_DONE=3'd7;
reg  [ 2:0] fst;
reg  [ 9:0] f_dy;
reg  [ 3:0] f_j, f_jl;
reg  [ 3:0] f_ysub;
reg  [ 2:0] f_mrow;
reg  [ 2:0] f_tc;
reg         f_tcv;
reg  [14:0] f_code;
reg         f_row_par;

// coda delle parole: {parita' riga, j, parola}
localparam QW = 1+4+32;
reg  [QW-1:0] q_mem [0:3];
reg  [ 2:0]   q_w, q_r;
wire          q_empty = (q_w == q_r);
wire          q_full  = (q_w[1:0] == q_r[1:0]) && (q_w[2] != q_r[2]);
wire [QW-1:0] q_head  = q_mem[q_r[1:0]];

// moltiplicazione della riga sorgente
wire [16:0] srcp   = {8'd0, f_dy[8:0]} * {8'd0, recip};
wire [ 7:0] src    = srcp[15:8];
wire [ 2:0] mrow_w = fy ? (ys - src[6:4]) : src[6:4];
wire [ 3:0] stride = (xs < 3'd1) ? 4'd1 : (xs < 3'd2) ? 4'd2 : (xs < 3'd4) ? 4'd4 : 4'd8;
wire [ 2:0] f_tcj  = f_j[3:1];
wire [ 2:0] mcol_w = fx ? (xs - f_tcj) : f_tcj;
wire [15:0] mapidx = mapr + {13'd0, f_mrow} * {12'd0, stride} + {13'd0, mcol_w};
wire        f_h    = fx ? ~f_j[0] : f_j[0];

// pixel
localparam [2:0] P_IDLE=3'd0, P_ROW=3'd1, P_COL=3'd2, P_DONE=3'd3;
reg  [ 2:0] pst;
reg  [ 9:0] p_dy;
reg  [ 4:0] p_c;                  // colonna corrente (0..15), 5 bit per lo scorrimento
reg         p_row_par;
reg  [ 7:0] p_y;
reg  [31:0] w_cur, w_prv;
reg  [ 3:0] j_cur, j_prv;
reg         cur_v, prv_v;

wire [ 3:0] pc       = p_c[3:0];
wire [ 6:0] klo      = t_klo[pc];
wire [ 6:0] khi      = t_khi[pc];
wire [ 3:0] jlo      = klo[6:3];
wire [ 3:0] jhi      = khi[6:3];
wire [ 2:0] nlo      = fx ? ~klo[2:0] : klo[2:0];
wire [ 2:0] nhi      = fx ? ~khi[2:0] : khi[2:0];
wire        have_hi  = cur_v && (j_cur == jhi);
wire        have_lo  = (cur_v && (j_cur == jlo)) || (prv_v && (j_prv == jlo));
wire [31:0] wlo      = (cur_v && (j_cur == jlo)) ? w_cur : w_prv;
wire [ 3:0] pix_lo   = wlo[{nlo, 2'b00} +: 4];
wire [ 3:0] pix_hi   = w_cur[{nhi, 2'b00} +: 4];
wire [ 3:0] pix_c    = (pix_hi != 4'hf) ? pix_hi : pix_lo;
// riga sullo schermo per dy
wire [ 8:0] vr_p     = v0r + p_dy[8:0];
wire [ 8:0] y_p      = flip ? (vsize - 9'd1 - vr_p) : vr_p;
// prossima colonna nell ordine
wire [ 4:0] p_cnext  = flip ? (p_c - 5'd1) : (p_c + 5'd1);


always @(posedge clk) begin
	we <= 1'b0;
	// tabella: stadi 1 e 2, e scrittura allo stadio 3
	s1_v   <= (wst == W_TAB) && !tc[4];          // colonne 0..15
	s1_c   <= tcc;
	s1_d   <= a_c - ox;
	s2_v   <= s1_v;
	s2_c   <= s1_c;
	s2_d   <= s1_d;
	s2_dhz <= s1_d[6:0] * hz;
	if (s2_v) begin
		t_cov[s2_c] <= cov_c;
		t_klo[s2_c] <= klo_c[6:0];
		t_khi[s2_c] <= khi_c[6:0];
	end
	if (rst) begin
		wst <= W_IDLE; fst <= F_IDLE; pst <= P_IDLE;
		busy <= 1'b0; rom_cs <= 1'b0;
		q_w <= 3'd0; q_r <= 3'd0;
		s1_v <= 1'b0; s2_v <= 1'b0;
	end else begin
		// ---------------- lista ----------------
		case (wst)
		W_IDLE: if (start) begin
			busy      <= 1'b1;
			objr_addr <= PTR;
			cnt_spr   <= 16'd0;
			a_first   <= flip ? (ax - x0) : (x0 + ax);
			wst       <= W_PTR;
		end
		W_PTR:  wst <= W_PTR2;
		W_PTR2: begin
			// MAME: puntatore oltre LAST = lista vuota
			first <= {objr_dout[6:0], 2'd0};
			slot  <= {objr_dout[6:0], 2'd0};
			pass  <= 1'b0;
			if ({objr_dout[6:0], 2'd0} > LAST) begin
				busy <= 1'b0;
				wst  <= W_IDLE;
			end else wst <= W_PTR3;
		end
		W_PTR3: begin
			objr_addr <= slot;
			rcnt      <= 3'd0;
			wst       <= W_RD;
		end
		// quattro parole in fila: l indirizzo della parola n e' presente nel
		// colpo rcnt = n, il dato nel colpo rcnt = n+1 (RAM registrata)
		W_RD: begin
			rcnt <= rcnt + 3'd1;
			if (rcnt < 3'd3) objr_addr <= slot + {6'd0, rcnt + 3'd1};
			case (rcnt)
				3'd1: w0 <= objr_dout;
				3'd2: w1 <= objr_dout;
				3'd3: begin
					w2  <= objr_dout;
					osh <= !hud[slot[8:2]] ? 9'd0 : (xcol < zlo) ? sh_lo : (xcol >= zhi) ? sh_hi : sh_mid;
				end
				3'd4: begin w3 <= objr_dout; oxr <= w1[8:0] + osh; wst <= W_EVAL; end
				default: ;
			endcase
		end
		W_EVAL: begin
			if (s_en && (s_pri == pass) && hit_x && hit_y) begin
				hz     <= hz_w;
				km     <= kmax;
				fx     <= s_fx;
				fy     <= s_fy;
				s_prir <= s_pri;
				colr   <= w2[3:0];
				xs     <= xsize;
				ys     <= ysize;
				mapr   <= w3;
				recip  <= recip_w;
				v0r    <= v0;
				dy_a   <= dy_a_w;
				dy_b   <= dy_b_w;
				tc     <= 5'd0;
				wst    <= W_TAB;
			end else wst <= W_NEXT;
		end
		// tabella: tc emette le colonne 0..15, i due stadi le scrivono due
		// colpi dopo; al colpo in cui tc vale 18 e' completa e l avvio del
		// disegno (sotto) decide se c e' qualcosa da fare
		W_TAB: begin
			if (tc != 5'd18) tc <= tc + 5'd1;
			else             wst <= W_DRAW;
		end
		W_DRAW: ;                           // fetcher e pixel lavorano
		W_NEXT: begin
			if (slot == LAST) begin
				if (pass) begin
					busy <= 1'b0;
					wst  <= W_IDLE;
				end else begin
					pass      <= 1'b1;
					slot      <= first;
					objr_addr <= first;
					rcnt      <= 3'd0;
					wst       <= W_RD;
				end
			end else begin
				slot      <= slot + 9'd4;
				objr_addr <= slot + 9'd4;
				rcnt      <= 3'd0;
				wst       <= W_RD;
			end
		end
		default: wst <= W_IDLE;
		endcase

		// ---------------- avvio del disegno ----------------
		// (W_TAB -> W_DRAW: la tabella e' completa al colpo in cui tc vale 18)
		if (wst == W_TAB && tc == 5'd18) begin
			if (!cov_any || dy_a >= dy_b) begin
				wst <= W_NEXT;
			end else begin
				cnt_spr  <= cnt_spr + 16'd1;
				k_first  <= t_klo[c_first_w[3:0]];
				k_last   <= t_khi[c_last_w[3:0]];
				c_first  <= c_first_w;
				fst      <= F_ROW;
				f_dy     <= dy_a;
				f_row_par<= 1'b0;
				pst      <= P_ROW;
				p_dy     <= dy_a;
				p_row_par<= 1'b0;
				q_w      <= 3'd0;
				q_r      <= 3'd0;
			end
		end

		// ---------------- fetcher ----------------
		case (fst)
		F_IDLE: ;
		F_ROW: if (f_dy == dy_b) begin
			fst <= F_DONE;
		end else begin
			f_ysub <= src[3:0] ^ {4{fy}};
			f_mrow <= mrow_w;
			f_j    <= k_first[6:3];
			f_jl   <= k_last[6:3];
			f_tcv  <= 1'b0;
			fst    <= F_LUT;
		end
		F_LUT: begin
			if (f_tcv && (f_tcj == f_tc)) fst <= F_ROM;
			else begin
				objl_addr <= {2'd0, mapidx[12:0]};
				f_tc      <= f_tcj;
				fst       <= F_LUT2;
			end
		end
		F_LUT2: fst <= F_LUT3;
		F_LUT3: begin
			f_code <= objl_dout[14:0] & cmask;
			f_tcv  <= 1'b1;
			fst    <= F_ROM;
		end
		// richiesta solo con l indirizzo vero (vedi lo strato di tile)
		F_ROM: begin
			rom_addr <= {f_code, f_ysub, f_h};
			rom_cs   <= 1'b1;
			fst      <= F_PUSH;
		end
		F_PUSH: if (rom_ok && !q_full) begin
			q_mem[q_w[1:0]] <= {f_row_par, f_j, rom_data};
			q_w    <= q_w + 3'd1;
			rom_cs <= 1'b0;
			if (f_j == f_jl) begin
				f_dy      <= f_dy + 10'd1;
				f_row_par <= ~f_row_par;
				fst       <= F_ROW;
			end else begin
				f_j <= f_j + 4'd1;
				fst <= F_LUT;
			end
		end
		F_DONE: ;
		default: fst <= F_IDLE;
		endcase

		// ---------------- pixel ----------------
		case (pst)
		P_IDLE: ;
		P_ROW: if (p_dy == dy_b) begin
			pst <= P_DONE;
		end else begin
			p_y   <= y_p[7:0];
			p_c   <= c_first;
			cur_v <= 1'b0;
			prv_v <= 1'b0;
			pst   <= P_COL;
		end
		P_COL: begin
			if (!t_cov[pc]) begin
				// fine delle colonne coperte di questa riga
				p_dy      <= p_dy + 10'd1;
				p_row_par <= ~p_row_par;
				pst       <= P_ROW;
			end else if (have_hi && have_lo) begin
				if (pix_c != 4'hf) begin
					we    <= 1'b1;
					waddr <= {pc, p_y};
					wdata <= {s_prir, colr, pix_c};
				end
				if (p_cnext[4] || !t_cov[p_cnext[3:0]]) begin
					p_dy      <= p_dy + 10'd1;
					p_row_par <= ~p_row_par;
					pst       <= P_ROW;
				end else p_c <= p_cnext;
			end else if (!q_empty && (q_head[QW-1] == p_row_par)) begin
				// avanza di una parola
				w_prv <= w_cur;  j_prv <= j_cur;  prv_v <= cur_v;
				w_cur <= q_head[31:0];
				j_cur <= q_head[35:32];
				cur_v <= 1'b1;
				q_r   <= q_r + 3'd1;
			end
		end
		P_DONE: ;
		default: pst <= P_IDLE;
		endcase

		if (fst == F_DONE && pst == P_DONE) begin
			fst    <= F_IDLE;
			pst    <= P_IDLE;
			rom_cs <= 1'b0;
			wst    <= W_NEXT;
		end
	end
end

endmodule

// =========================================================================
// Il modulo: raster d uscita, strisce, composizione, anello, fusione
// =========================================================================
module jtpspike_video_rot(
	input             rst,
	input             clk,
	input             pxl_cen,

	input             rot_req,       // CRT Rotate acceso (dal Template)
	input             rot_ccw_req,   // 1 = antiorario
	input             rot_cut_req,   // 0 = fusione (tutte le colonne), 1 = taglio (una colonna per riga)
	input      [ 4:0] rot_pos_req,   // taglio: posizione della finestra, scatti di 8 colonne, con segno (-8..+8)
	input             rot_follow_req,// taglio: la finestra segue le navi (camera)
	input      [15:0] cam_x0, cam_x1, cam_x2,   // colonne delle navi (rm_rot_cam)
	input      [ 2:0] cam_on,                   // navi in gioco
	input     [127:0] rot_hud,                  // posti sprite del chip 1 che sono scritte (rm_rot_cam)
	output reg        rot_act,       // rotazione attiva: le porte passano qui

	// stato del gioco
	input             flip,
	input      [31:0] gfxbank,
	input      [ 8:0] scrx1, scry, scry1,
	input      [15:0] ras_dout,      // rasterram[7]: scroll X dello strato 0
	// costanti per gioco, calcolate in jtpspike_video
	input      [ 8:0] visx, xnudge, xb0, xb1, xf0, xf1, yb,
	input      [ 8:0] xorg, xfo, obj_yoffs,
	input      [14:0] cmask0, cmask1,

	// GGA
	input      [ 8:0] H, h_last, vdump, hsize, vsize,
	input             HS,

	// RAM del gioco (porta video)
	output     [12:1] scr_addr,   input [15:0] scr_vram,
	output     [12:1] scr1v_addr, input [15:0] scr1_vram,
	output     [ 9:1] objr_addr,  input [15:0] objr_dout,
	output     [ 9:1] objr1_addr, input [15:0] objr1_dout,
	output     [15:1] objl_addr,  input [15:0] objl_dout,
	output     [15:1] objl1_addr, input [15:0] objl1_dout,
	output reg [11:1] mix_addr,   input [15:0] mix_pal,

	// ROM (slot SDRAM)
	output     [19:2] scr0_addr, output scr0_cs, input [31:0] scr0_data, input scr0_ok,
	output     [20:2] scr1_addr, output scr1_cs, input [31:0] scr1_data, input scr1_ok,
	output     [21:2] obj0_addr, output obj0_cs, input [31:0] obj0_data, input obj0_ok,
	output     [20:2] obj1_addr, output obj1_cs, input [31:0] obj1_data, input obj1_ok,

	// uscita
	output reg [ 7:0] rot_r, rot_g, rot_b,
	output reg        rot_ce,
	output reg        rot_hb, rot_vb, rot_vs
);

// =====================================================================
// Quadro: righe del quadro, inizio del calcolo, cambio di modo
// =====================================================================
reg  [8:0] vdump_l;
reg  [8:0] v_last = 9'd255;
reg        fpar;
reg        ccw;
reg  [8:0] W;                      // colonne del gioco (hsize)
reg  [7:0] Hr;                     // righe del gioco (vsize)
reg  [8:0] N;                      // righe visibili d uscita
reg        hs_l;
reg        cut;                    // taglio invece della fusione
reg  [4:0] cpos;                   // posizione del taglio (con segno)
reg        follow;                 // taglio: la finestra segue le navi

wire vchg   = (vdump != vdump_l);
wire fstart = vchg && (vdump == v_last);   // inizio della riga v_last

always @(posedge clk) begin
	vdump_l <= vdump;
	hs_l    <= HS;
	if (vchg && (vdump == 9'd0)) v_last <= vdump_l;
	if (rst) begin
		rot_act <= 1'b0;
		fpar    <= 1'b0;
		follow  <= 1'b0;
	end else if (fstart) begin
		rot_act <= rot_req;
		ccw     <= rot_ccw_req;
		cut     <= rot_cut_req;
		cpos    <= rot_pos_req;
		follow  <= rot_follow_req;
		W       <= hsize;
		Hr      <= vsize[7:0];
		N       <= v_last + 9'd1 - 9'd23;
		fpar    <= ~fpar;
	end
end

// reciproco di W per la normalizzazione: recipW = floor((2^18 + W/2) / W),
// cioe' round(2^18 / W). Divisione con resto, un bit per colpo, a inizio quadro.
reg  [18:0] dv_num;
reg  [ 9:0] dv_rem;
reg  [18:0] dv_q;
reg  [ 4:0] dv_n = 5'd0;
reg  [ 9:0] recipW;
wire [ 9:0] dv_r2 = {dv_rem[8:0], dv_num[18]};
always @(posedge clk) begin
	if (fstart) begin
		dv_num <= (19'd1 << 18) + {11'd0, hsize[8:1]};
		dv_rem <= 10'd0;
		dv_q   <= 19'd0;
		dv_n   <= 5'd19;
	end else if (dv_n != 5'd0) begin
		dv_n   <= dv_n - 5'd1;
		dv_num <= {dv_num[17:0], 1'b0};
		if (dv_r2 >= {1'b0, W}) begin
			dv_rem <= dv_r2 - {1'b0, W};
			dv_q   <= {dv_q[17:0], 1'b1};
		end else begin
			dv_rem <= dv_r2;
			dv_q   <= {dv_q[17:0], 1'b0};
		end
		if (dv_n == 5'd1) recipW <= (dv_r2 >= {1'b0, W}) ? {dv_q[8:0], 1'b1} : {dv_q[8:0], 1'b0};
	end
end

// =====================================================================
// Raster d uscita: 608 pixel da 6 colpi, allineati alla riga del gioco
// =====================================================================
wire line_start = pxl_cen && (H == h_last);    // al colpo dopo H = 0
reg  [2:0] s6;
reg  [9:0] ohcnt;
always @(posedge clk) begin
	if (line_start) begin
		s6    <= 3'd0;
		ohcnt <= 10'd0;
	end else if (s6 == 3'd5) begin
		s6    <= 3'd0;
		ohcnt <= ohcnt + 10'd1;
	end else s6 <= s6 + 3'd1;
	rot_ce <= (s6 == 3'd4) && !line_start;    // alto nell ultimo colpo del pixel
end

// finestra orizzontale centrata dove sta quella del gioco: centro a W*4 colpi
// dall inizio della riga, larghezza Hr pixel da 6 colpi.
//   o_start = floor((W*4 - Hr*3) / 6)  (683/4096 = 1/6 esatto per x < 2000)
wire [10:0] o_num   = {W, 2'b00} - ({3'd0, Hr} + {2'd0, Hr, 1'b0});
wire [21:0] o_mul   = o_num * 11'd683;
wire [ 9:0] o_start = o_mul[21:12];
wire [ 9:0] o_end   = o_start + {2'd0, Hr};

// TAGLIO: le N righe mostrano le colonne u = ustart .. ustart+N-1, una per
// riga, senza fusione. Le colonne in piu' sono E = W - N (119 Turbo Force, 93
// Aero Fighters); la finestra parte centrata (E/2) e si sposta di 8 colonne per
// scatto: + = finestra piu' in basso nel quadro girato. Fuori da [0, E] si ferma.
wire [ 9:0] cut_e  = (W > N) ? ({1'b0, W} - {1'b0, N}) : 10'd0;
wire [11:0] cut_s  = {3'b000, cut_e[9:1]} + {{4{cpos[4]}}, cpos, 3'b000};   // a complemento a due
reg  [ 8:0] ufix;                  // finestra ferma, dalla posizione del menu
reg  [ 8:0] cam;                   // finestra della camera
reg  [ 8:0] ustart;
always @(posedge clk) begin
	ufix   <= cut_s[11] ? 9'd0 : (cut_s[9:0] > cut_e) ? cut_e[8:0] : cut_s[8:0];
	ustart <= !follow ? ufix : ({1'b0, cam} > cut_e) ? cut_e[8:0] : cam;
end

// CAMERA (Follow): la finestra segue le navi come la camera di Darius rework
// (darius_followcam). Bersaglio = centro fra la prima e l ultima nave in gioco,
// finestra voluta = bersaglio - N/2 fermata in [0, E]; a ogni quadro la camera
// va verso la voluta di 4 / 2 / 1 colonne se manca >= 64 / >= 16 / > 4,
// altrimenti sta ferma. Nessuna nave in gioco: verso il centro (E/2, come la
// posizione 0). Si muove solo a inizio quadro, insieme agli altri parametri,
// quindi la finestra resta la stessa per tutto il quadro; i conti sono a stadi
// registrati, pronti da migliaia di colpi. A rotazione, taglio o camera spenti
// resta sulla finestra ferma: accendendola parte da li'.
// Colonna d uscita u = colonna in CW, W-1-colonna in CCW; col flip la colonna
// e' W-1-colonna (vedi jtpspike_rot_snoop).
wire [ 8:0] wm1  = W - 9'd1;
wire        cmir = flip ^ ccw;
reg  [ 8:0] cu0, cu1, cu2, cmin, cmax, cdes, cstp;
reg  [ 2:0] con;
reg         cany, cany3, cneg;
reg  [ 9:0] csum;
reg  [10:0] cerr;

// colonna della nave fermata in [0, W-1]
function [8:0] cam_col(input [15:0] x, input [8:0] lim);
	cam_col = x[15] ? 9'd0 : (x > {7'd0, lim}) ? lim : x[8:0];
endfunction

wire [ 8:0] cc0  = cam_col(cam_x0, wm1);
wire [ 8:0] cc1  = cam_col(cam_x1, wm1);
wire [ 8:0] cc2  = cam_col(cam_x2, wm1);
wire [ 8:0] lo0  = con[0] ? cu0 : 9'h1ff, lo1 = con[1] ? cu1 : 9'h1ff, lo2 = con[2] ? cu2 : 9'h1ff;
wire [ 8:0] hi0  = con[0] ? cu0 : 9'd0,   hi1 = con[1] ? cu1 : 9'd0,   hi2 = con[2] ? cu2 : 9'd0;
wire [ 8:0] lo01 = (lo0 < lo1) ? lo0 : lo1;
wire [ 8:0] hi01 = (hi0 > hi1) ? hi0 : hi1;
wire [10:0] cdraw = {2'b00, csum[9:1]} - {3'b000, N[8:1]};       // bersaglio - N/2, con segno
wire [10:0] cabs  = cerr[10] ? (~cerr + 11'd1) : cerr;

always @(posedge clk) begin
	// 1: colonne d uscita delle navi
	cu0   <= cmir ? (wm1 - cc0) : cc0;
	cu1   <= cmir ? (wm1 - cc1) : cc1;
	cu2   <= cmir ? (wm1 - cc2) : cc2;
	con   <= cam_on;
	// 2: la prima e l ultima fra quelle in gioco
	cmin  <= (lo01 < lo2) ? lo01 : lo2;
	cmax  <= (hi01 > hi2) ? hi01 : hi2;
	cany  <= |con;
	// 3: doppio del bersaglio
	csum  <= {1'b0, cmin} + {1'b0, cmax};
	cany3 <= cany;
	// 4: finestra voluta
	cdes  <= !cany3 ? cut_e[9:1] : cdraw[10] ? 9'd0 : (cdraw[9:0] > cut_e) ? cut_e[8:0] : cdraw[8:0];
	// 5: quanto manca, con segno
	cerr  <= {2'b00, cdes} - {2'b00, cam};
	// 6: passo
	cneg  <= cerr[10];
	cstp  <= (cabs >= 11'd64) ? 9'd4 : (cabs >= 11'd16) ? 9'd2 : (cabs > 11'd4) ? 9'd1 : 9'd0;
	if (rst)
		cam <= 9'd0;
	else if (fstart)
		cam <= (rot_act && cut && follow) ? (cneg ? (cam - cstp) : (cam + cstp)) : ufix;
end

// riga d uscita: vdump in [16, 16+N)
wire [8:0] lrow   = vdump - 9'd16;
wire       lvis   = (vdump >= 9'd16) && (lrow < N) && rot_act;

// VSync d uscita: righe 0..3 del gioco, fronti all HSync che scende (come il GGA)
always @(posedge clk) if (hs_l && !HS) rot_vs <= (vdump < 9'd4);

// =====================================================================
// Pesi della riga (DDA intero): la riga l copre [l*W, (l+1)*W) in unita'
// di 1/N di colonna. c0 = prima colonna, f = l*W - c0*N.
// =====================================================================
// Tutto a 10 bit: f < N <= 255, e = f + W < 3N.
// (stato del produttore dichiarato qui perche' serve gia' a cons_c0)
localparam [2:0] PR_IDLE=3'd0, PR_CLR=3'd1, PR_GO=3'd2, PR_REND=3'd3, PR_WAIT=3'd4, PR_COMP=3'd5, PR_NEXT=3'd6;
reg  [2:0] pr;
reg  [8:0] c0;            // prima colonna (ordine di uscita u)
reg  [8:0] f;
reg  [8:0] wt0, wt1, wt2;
reg  [8:0] cons_c0;       // per il produttore: le colonne sotto c0 sono libere

wire [9:0] N10   = {1'b0, N};
wire [9:0] N2    = {N, 1'b0};
wire [9:0] f_w   = {1'b0, f} + {1'b0, W};             // f + W
wire [9:0] f_nx  = (f_w >= N2) ? (f_w - N2) : (f_w >= N10) ? (f_w - N10) : f_w;
wire [8:0] c_inc = (f_w >= N2) ? 9'd2 : (f_w >= N10) ? 9'd1 : 9'd0;
wire       lvis_next = (vdump >= 9'd16) && ((vdump - 9'd16) < N);

// pesi della riga che parte da f: e = f + W
//   w0 = min(e, N) - f,  w1 = min(e, 2N) - N se e > N,  w2 = e - 2N se e > 2N
task set_w(input [9:0] ff);
	reg [9:0] e, w1e, w2e;
	begin
		e   = ff + {1'b0, W};
		wt0 <= ((e < N10) ? e[8:0] : N) - ff[8:0];
		w1e  = (e > N10) ? (((e < N2) ? e : N2) - N10) : 10'd0;
		w2e  = (e > N2)  ? (e - N2) : 10'd0;
		wt1 <= w1e[8:0];                     // <= N, sta in 9 bit
		wt2 <= w2e[8:0];
	end
endtask

always @(posedge clk) begin
	if (fstart) begin
		c0 <= 9'd0;
		f  <= 9'd0;
	end else if (vchg && lvis_next) begin
		if (cut) begin
			// taglio: una colonna intera per riga (peso W = tutto)
			c0  <= (vdump == 9'd16) ? ustart : (c0 + 9'd1);
			wt0 <= W;
			wt1 <= 9'd0;
			wt2 <= 9'd0;
		end else if (vdump == 9'd16) begin
			c0 <= 9'd0;
			f  <= 9'd0;
			set_w(10'd0);
		end else begin
			// riga dopo: f += W, c0 += 1 o 2
			c0 <= c0 + c_inc;
			f  <= f_nx[8:0];
			set_w(f_nx);
		end
	end
	// prima che l uscita parta le colonne libere sono quelle sotto la prima
	// che servira' (0 nella fusione, ustart nel taglio)
	if (fstart)            cons_c0 <= 9'd0;
	else if (lvis)         cons_c0 <= c0;
	else if (pr == PR_CLR) cons_c0 <= cut ? ustart : 9'd0;
end

// =====================================================================
// Produttore: strisce di 16 colonne in ordine d uscita
// =====================================================================
reg  [ 4:0] sn;               // striscia (0..21)
reg  [ 4:0] ns;               // strisce nel quadro
reg  [ 8:0] x0;               // prima colonna nativa della striscia
reg  [12:0] clr;
reg         eng_go;
reg  [ 8:0] cols_done;
reg  [12:0] cp;               // composizione: {colonna, riga}
reg         cp_run;
reg  [11:0] cp_a1;            // composizione: indirizzo del dato presente
reg         cp_v1;
reg  [11:0] cl_a;             // pulizia dietro la composizione
reg         cl_we;
wire        cp_tail = cp_v1 | cl_we;

// a inizio quadro i motori ripartono puliti (un quadro interrotto non lascia
// lavoro a meta')
wire eng_rst = rst | fstart;
wire t0_busy, t1_busy, o0_busy, o1_busy;
wire eng_busy = t0_busy | t1_busy | o0_busy | o1_busy;
// ultima striscia: tutte nella fusione, fino alla colonna ustart+N-1 nel taglio
wire [9:0] cut_last = {1'b0, ustart} + {1'b0, N} - 10'd1;
wire [4:0] s_last   = cut ? cut_last[8:4] : (ns - 5'd1);

always @(posedge clk) begin
	eng_go <= 1'b0;
	if (rst) begin
		pr <= PR_IDLE;
	end else if (fstart) begin
		cols_done <= 9'd0;
		if (rot_req) begin
			ns  <= hsize[8:4];
			sn  <= 5'd0;
			clr <= 13'd0;
			pr  <= PR_CLR;
		end else pr <= PR_IDLE;
	end else case (pr)
	PR_IDLE: ;
	// buffer degli sprite trasparenti a inizio quadro (anche dopo un quadro
	// interrotto); intanto W, N e ustart sono pronti: la prima striscia e' 0
	// nella fusione, quella di ustart nel taglio
	PR_CLR: begin
		clr <= clr + 13'd1;
		if (clr == 13'd4095) begin
			sn <= cut ? ustart[8:4] : 5'd0;
			pr <= PR_GO;
		end
	end
	PR_GO: begin
		x0     <= ccw ? (W - 9'd16 - {sn, 4'd0}) : {sn, 4'd0};
		eng_go <= 1'b1;
		pr     <= PR_REND;
	end
	PR_REND: if (!eng_go && !eng_busy) pr <= PR_WAIT;
	// l anello ha posto: le colonne di questa striscia sostituiscono quelle
	// 64 prima, che l uscita ha gia' passato
	PR_WAIT: if ({sn, 4'd0} + 9'd16 <= cons_c0 + 9'd64) begin
		cp     <= 13'd0;
		cp_run <= 1'b1;
		pr     <= PR_COMP;
	end
	PR_COMP: if (!cp_run && !cp_tail) begin
		cols_done <= cols_done + 9'd16;
		if (sn == s_last) pr <= PR_IDLE;
		else begin
			sn <= sn + 5'd1;
			pr <= PR_GO;
		end
	end
	default: pr <= PR_IDLE;
	endcase
	// avanzamento della composizione: righe 0..Hr-1 di ogni colonna
	if (pr == PR_COMP && cp_run) begin
		if (cp[7:0] == Hr - 8'd1) begin
			if (cp[11:8] == 4'd15) cp_run <= 1'b0;
			cp <= {1'b0, cp[11:8] + 4'd1, 8'd0};
		end else cp <= cp + 13'd1;
	end
end

// ---------------- conti per pixel, dai moduli di Andrea ----------------
// Strato 0: scroll X da rasterram[7] (turbofrc/aerofgt: stessa parola per
// tutte le righe), scroll Y dal registro. Strato 1: registri.
wire [8:0] sxb0 = ras_dout[8:0] - xb0;
wire [8:0] sxb1 = scrx1 - xb1;
wire [8:0] syb0 = scry  + yb;
wire [8:0] syb1 = scry1 + yb;
// senza flip mx = x + visx + xnudge + scrx_base, my = y + scry_base
// col flip   mx = 511 - x + visx - xnudge + scrx_base + hsize + xflip
//            my = 511 - y + scry_base + vsize
// sprite: indirizzo di line buffer della colonna x
// senza flip A = x + xorg + xnudge;  col flip A = 511 - x + xorg - xnudge + hsize + xfo
// Registrati (valori che cambiano solo coi registri del gioco): le loro somme
// non stanno nel cammino dei motori.
reg  [8:0] kx0, kx1, ky0, ky1, axs;
always @(posedge clk) begin
	kx0 <= flip ? (9'd511 + visx - xnudge + sxb0 + hsize + xf0) : (visx + xnudge + sxb0);
	kx1 <= flip ? (9'd511 + visx - xnudge + sxb1 + hsize + xf1) : (visx + xnudge + sxb1);
	ky0 <= flip ? (9'd511 + syb0 + vsize) : syb0;
	ky1 <= flip ? (9'd511 + syb1 + vsize) : syb1;
	axs <= flip ? (9'd511 + xorg - xnudge + hsize + xfo) : (xorg + xnudge);
end

// SCRITTE nel taglio: le scritte a posizione fissa marcate da rm_rot_cam
// (punteggio, INSERT COIN, CREDIT) si spostano con la finestra, in Fixed e in
// Follow. Quella vicina a un bordo del quadro resta alla stessa distanza dal
// bordo della finestra, quella in mezzo resta in mezzo alla finestra. Zone
// sulla colonna mostrata dello sprite: < W/4 primo bordo, >= W-W/4 secondo,
// altrimenti centro. Colonne mostrate dalla finestra: [sn, sn+N), sn = ustart
// in CW, E-ustart in CCW. Scarti in colonne mostrate: sn, sn-E, sn-E/2; nel
// line buffer col flip il segno si inverte (A = ax - x). Fermi per tutto il
// quadro come ustart; fuori dal taglio zero.
reg  [8:0] h_sn, h_dlo, h_dmid, h_dhi, h_zlo, h_zhi;
always @(posedge clk) begin
	h_sn   <= ccw ? (cut_e[8:0] - ustart) : ustart;
	h_dlo  <= !(rot_act && cut) ? 9'd0 : flip ? (9'd0 - h_sn)          : h_sn;
	h_dhi  <= !(rot_act && cut) ? 9'd0 : flip ? (cut_e[8:0] - h_sn)    : (h_sn - cut_e[8:0]);
	h_dmid <= !(rot_act && cut) ? 9'd0 : flip ? (cut_e[9:1] - h_sn)    : (h_sn - cut_e[9:1]);
	h_zlo  <= {2'b00, W[8:2]};
	h_zhi  <= W - {2'b00, W[8:2]};
end

// ---------------- motori ----------------
wire        t0_we, t1_we, o0_we, o1_we;
wire [11:0] t0_wa, t1_wa, o0_wa, o1_wa;
wire [ 6:0] t0_wd, t1_wd;
wire [ 8:0] o0_wd, o1_wd;
wire [11:0] t0_va, t1_va;
wire [17:0] t0_ra, t1_ra;
wire [19:0] o0_ra, o1_ra;
wire [15:0] o0_cnt, o1_cnt;

jtpspike_rot_tile u_t0(
	.rst(eng_rst), .clk(clk), .start(eng_go), .busy(t0_busy),
	.x0(x0), .rows(Hr), .flip(flip), .kx(kx0), .ky(ky0),
	.layer(1'b0), .gfxbank(gfxbank),
	.vram_addr(t0_va), .vram_data(scr_vram),
	.rom_addr(t0_ra), .rom_cs(scr0_cs), .rom_data(scr0_data), .rom_ok(scr0_ok),
	.we(t0_we), .waddr(t0_wa), .wdata(t0_wd)
);
jtpspike_rot_tile u_t1(
	.rst(eng_rst), .clk(clk), .start(eng_go), .busy(t1_busy),
	.x0(x0), .rows(Hr), .flip(flip), .kx(kx1), .ky(ky1),
	.layer(1'b1), .gfxbank(gfxbank),
	.vram_addr(t1_va), .vram_data(scr1_vram),
	.rom_addr(t1_ra), .rom_cs(scr1_cs), .rom_data(scr1_data), .rom_ok(scr1_ok),
	.we(t1_we), .waddr(t1_wa), .wdata(t1_wd)
);
jtpspike_rot_obj u_o0(
	.rst(eng_rst), .clk(clk), .start(eng_go), .busy(o0_busy),
	.x0(x0), .vsize({1'b0, Hr}), .flip(flip), .ax(axs), .yoffs(obj_yoffs), .cmask(cmask0),
	.hud(128'd0), .sh_lo(h_dlo), .sh_mid(h_dmid), .sh_hi(h_dhi), .zlo(h_zlo), .zhi(h_zhi),
	.objr_addr(objr_addr), .objr_dout(objr_dout),
	.objl_addr(objl_addr), .objl_dout(objl_dout),
	.rom_addr(o0_ra), .rom_cs(obj0_cs), .rom_data(obj0_data), .rom_ok(obj0_ok),
	.we(o0_we), .waddr(o0_wa), .wdata(o0_wd), .cnt_spr(o0_cnt)
);
jtpspike_rot_obj u_o1(
	.rst(eng_rst), .clk(clk), .start(eng_go), .busy(o1_busy),
	.x0(x0), .vsize({1'b0, Hr}), .flip(flip), .ax(axs), .yoffs(obj_yoffs), .cmask(cmask1),
	.hud(rot_hud), .sh_lo(h_dlo), .sh_mid(h_dmid), .sh_hi(h_dhi), .zlo(h_zlo), .zhi(h_zhi),
	.objr_addr(objr1_addr), .objr_dout(objr1_dout),
	.objl_addr(objl1_addr), .objl_dout(objl1_dout),
	.rom_addr(o1_ra), .rom_cs(obj1_cs), .rom_data(obj1_data), .rom_ok(obj1_ok),
	.we(o1_we), .waddr(o1_wa), .wdata(o1_wd), .cnt_spr(o1_cnt)
);

assign scr_addr   = t0_va;
assign scr1v_addr = t1_va;
assign scr0_addr  = t0_ra;
assign scr1_addr  = {1'b0, t1_ra};
assign obj0_addr  = o0_ra;
assign obj1_addr  = o1_ra[18:0];

// ---------------- buffer di striscia ----------------
wire [ 6:0] t0_q, t1_q;
wire [ 8:0] o0_q, o1_q;
wire [11:0] cp_ra = cp[11:0];

// sprite: scrive il motore, oppure la pulizia (inizio quadro e dietro la
// composizione, un colpo dopo la lettura)
wire        o_clr_frame = (pr == PR_CLR);
wire        o0_bwe = o_clr_frame ? 1'b1 : cl_we ? 1'b1 : o0_we;
wire        o1_bwe = o_clr_frame ? 1'b1 : cl_we ? 1'b1 : o1_we;
wire [11:0] o0_bwa = o_clr_frame ? clr[11:0] : cl_we ? cl_a : o0_wa;
wire [11:0] o1_bwa = o_clr_frame ? clr[11:0] : cl_we ? cl_a : o1_wa;
wire [ 8:0] o0_bwd = (o_clr_frame | cl_we) ? 9'h00f : o0_wd;
wire [ 8:0] o1_bwd = (o_clr_frame | cl_we) ? 9'h00f : o1_wd;

jtpspike_rot_ram #(.DW(7), .AW(12)) u_bt0(.clk(clk), .we(t0_we), .waddr(t0_wa), .wdata(t0_wd), .raddr(cp_ra), .q(t0_q));
jtpspike_rot_ram #(.DW(7), .AW(12)) u_bt1(.clk(clk), .we(t1_we), .waddr(t1_wa), .wdata(t1_wd), .raddr(cp_ra), .q(t1_q));
jtpspike_rot_ram #(.DW(9), .AW(12)) u_bo0(.clk(clk), .we(o0_bwe), .waddr(o0_bwa), .wdata(o0_bwd), .raddr(cp_ra), .q(o0_q));
jtpspike_rot_ram #(.DW(9), .AW(12)) u_bo1(.clk(clk), .we(o1_bwe), .waddr(o1_bwa), .wdata(o1_bwd), .raddr(cp_ra), .q(o1_q));

// ---------------- composizione ----------------
// cp e' gia' un registro e va dritto all indirizzo delle RAM di striscia: il
// dato dell indirizzo cp c e' nel colpo dopo, insieme a cp_a1. Mixer di
// jtpspike_video (two):
//   o1 pri ? o1 : o0 pri ? o0 : strato 1 opaco ? s1 : o1 ? o1 : o0 ? o0 : s0
// Indici di palette a 10 bit (il bit 10 e' sempre 0 su turbofrc/aerofgt):
//   s0 {00,0,pal,pix}  s1 {01,0,pal,pix}  o0 {10,col,pix}  o1 {11,col,pix}
always @(posedge clk) begin
	cp_v1 <= (pr == PR_COMP) && cp_run;
	cp_a1 <= cp[11:0];
	cl_we <= cp_v1;                // pulisce cio' che ha appena letto
	cl_a  <= cp_a1;
end

wire        s1op = (t1_q[3:0] != 4'hf);
wire        o0op = (o0_q[3:0] != 4'hf);
wire        o1op = (o1_q[3:0] != 4'hf);
wire [ 9:0] mix_idx = (o1op & o1_q[8]) ? {2'b11, o1_q[7:0]} :
                      (o0op & o0_q[8]) ? {2'b10, o0_q[7:0]} :
                       s1op            ? {2'b01, 1'b0, t1_q} :
                       o1op            ? {2'b11, o1_q[7:0]} :
                       o0op            ? {2'b10, o0_q[7:0]} :
                                         {2'b00, 1'b0, t0_q};

// colonna d uscita della colonna di striscia c: CW u = x, CCW u = W-1-x
wire [3:0]  cpc   = cp_a1[11:8];
wire [8:0]  u_cp  = ccw ? ({sn, 4'd0} + 9'd15 - {5'd0, cpc}) : ({sn, 4'd0} + {5'd0, cpc});

// ---------------- anello: 64 colonne x 256 righe ----------------
reg  [13:0] ring_ra;
wire [ 9:0] ring_q;
jtpspike_rot_ram #(.DW(10), .AW(14)) u_ring(
	.clk(clk), .we(cp_v1), .waddr({u_cp[5:0], cp_a1[7:0]}), .wdata(mix_idx),
	.raddr(ring_ra), .q(ring_q)
);

// etichette: quale colonna (e di quale quadro) sta in ogni posto dell anello
reg  [9:0] tag [0:63];
always @(posedge clk) if (cp_v1) tag[u_cp[5:0]] <= {fpar, u_cp};

// =====================================================================
// Consumatore: per ogni pixel d uscita 3 colonne, palette, fusione in luce
// =====================================================================
// Il pixel q si prepara nello slot q-2: indirizzi dell anello alle fasi 0..2
// (dati alle fasi 2..4), indirizzi di palette 2..4 (colori 4, 5 e 0 dello
// slot dopo), somme alle fasi 4, 5, 0; nello slot q-1: normalizzazione (1),
// indirizzo della radice (2), radice pronta alla fase 4, uscita al CE di fine
// slot q-1, mostrata nello slot q.
wire [ 9:0] q_px   = ohcnt + 10'd2;
wire [ 9:0] p_px   = q_px - o_start;
wire [ 7:0] y_px   = ccw ? p_px[7:0] : (Hr - 8'd1 - p_px[7:0]);
wire [ 8:0] u0 = c0, u1 = c0 + 9'd1, u2 = c0 + 9'd2;

reg  [8:0]  wa, wb, wc;          // pesi delle tre letture in volo
reg         va, vb, vc;
reg  [18:0] acc_r, acc_g, acc_b;
reg  [28:0] np_r, np_g, np_b;
reg  [ 9:0] la_r, la_g, la_b;
wire [ 7:0] lq_r, lq_g, lq_b;
reg  [23:0] fin;

function tag_ok(input [8:0] u);
	tag_ok = (tag[u[5:0]] == {fpar, u}) && (u < W);
endfunction

wire [4:0]  pr5 = mix_pal[14:10];
wire [4:0]  pg5 = mix_pal[ 9: 5];
wire [4:0]  pb5 = mix_pal[ 4: 0];
wire [9:0]  sr  = pr5 * pr5;
wire [9:0]  sg  = pg5 * pg5;
wire [9:0]  sb  = pb5 * pb5;

reg  [8:0]  wcur;
reg         vcur;
always @* begin
	case (s6)
		3'd4:    begin wcur = wa; vcur = va; end
		3'd5:    begin wcur = wb; vcur = vb; end
		default: begin wcur = wc; vcur = vc; end
	endcase
end
wire [18:0] pr_r = vcur ? (sr * wcur) : 19'd0;
wire [18:0] pr_g = vcur ? (sg * wcur) : 19'd0;
wire [18:0] pr_b = vcur ? (sb * wcur) : 19'd0;

function [9:0] nclamp(input [28:0] p);
	reg [10:0] m;
	begin
		m = p[28:18] + {10'd0, p[17]};
		nclamp = (m > 11'd1023) ? 10'd1023 : m[9:0];
	end
endfunction

always @(posedge clk) begin
	case (s6)
	3'd0: begin
		ring_ra <= {u0[5:0], y_px};
		wa <= wt0;  va <= tag_ok(u0) && (wt0 != 9'd0);
		// terza somma del pixel prima
		acc_r <= acc_r + pr_r;  acc_g <= acc_g + pr_g;  acc_b <= acc_b + pr_b;
	end
	3'd1: begin
		ring_ra <= {u1[5:0], y_px};
		wb <= wt1;  vb <= tag_ok(u1) && (wt1 != 9'd0);
		np_r <= acc_r * recipW;  np_g <= acc_g * recipW;  np_b <= acc_b * recipW;
	end
	3'd2: begin
		ring_ra  <= {u2[5:0], y_px};
		wc <= wt2;  vc <= tag_ok(u2) && (wt2 != 9'd0);
		mix_addr <= {1'b0, ring_q};
		la_r <= nclamp(np_r);  la_g <= nclamp(np_g);  la_b <= nclamp(np_b);
	end
	3'd3: begin
		mix_addr <= {1'b0, ring_q};
	end
	3'd4: begin
		mix_addr <= {1'b0, ring_q};
		acc_r <= pr_r;  acc_g <= pr_g;  acc_b <= pr_b;
		fin   <= {lq_r, lq_g, lq_b};
	end
	3'd5: begin
		acc_r <= acc_r + pr_r;  acc_g <= acc_g + pr_g;  acc_b <= acc_b + pr_b;
	end
	default: ;
	endcase
end

// radice in luce: lq = round(255 * sqrt(m) / 31); per m quadrato esatto c^2
// da' l espansione a 8 bit del 5 bit come il Template ({c, c[4:2]})
jtpspike_rot_sqrt u_sq_r(.clk(clk), .a(la_r), .q(lq_r));
jtpspike_rot_sqrt u_sq_g(.clk(clk), .a(la_g), .q(lq_g));
jtpspike_rot_sqrt u_sq_b(.clk(clk), .a(la_b), .q(lq_b));

// ---------------- uscita ----------------
wire       hnext = (ohcnt + 10'd1 >= o_start) && (ohcnt + 10'd1 < o_end);
always @(posedge clk) begin
	if (line_start) begin
		rot_hb <= 1'b1;
		{rot_r, rot_g, rot_b} <= 24'd0;
	end else if (s6 == 3'd5) begin
		rot_hb <= ~hnext;
		rot_vb <= ~lvis;
		{rot_r, rot_g, rot_b} <= (hnext && lvis) ? fin : 24'd0;
	end
end

// ---------------- banco ----------------
`ifdef SIMULATION
// colonne mostrate prima che fossero pronte (nere)
integer late_px = 0;
always @(posedge clk) if (s6 == 3'd0 && lvis && (q_px >= o_start) && (q_px < o_end)) begin
	if ((wt0 != 0 && !tag_ok(u0)) || (wt1 != 0 && !tag_ok(u1)) || (wt2 != 0 && !tag_ok(u2)))
		late_px <= late_px + 1;
end
`endif

endmodule

// =========================================================================
// Radice: 1024 x 8 bit, tabella generata dal banco (main.cpp, make_lut):
//   lut[m] = round(255 * sqrt(m) / 31), e per m = c^2 esatto {c, c[4:2]}.
// Il percorso parte dalla cartella del progetto, come gli altri .hex.
// =========================================================================
module jtpspike_rot_sqrt(
	input            clk,
	input      [9:0] a,
	output reg [7:0] q
);
	reg [7:0] lut [0:1023];
	initial $readmemh("rtl/pspike/rot_sqrt.hex", lut);
	always @(posedge clk) q <= lut[a];
endmodule
