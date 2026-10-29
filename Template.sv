// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of rmPowerSpikes_MiSTer.
    GPL-3.
    Template.sv di Night Slashers (Umberto Parisi, rmonic79), basato sul
    Template MiSTer di Sorgelig.
    Core di gioco: Andrea Bogazzi (jtpspike), non toccato.
*/

// Power Spikes — MiSTer core
// 68000 + Z80 + YM2610. Il core (gioco + modello di memoria + controller SDRAM)
// e' quello di Andrea: qui c'e' solo l'interfaccia verso sys, OSD, ingressi e video.

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [45:0] HPS_BUS,   // 46 bit dal sys di agosto 2026 (era 49: fb_en/sl ora li riporta sys_top)
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS,

	// CRT Adjust sys-side: valori dall'OSD + VBlank vero (vedi sys/emu_ports.vh)
	output              CRT_ON,
	output signed [4:0] CRT_HSIZE,
	output signed [8:0] CRT_HPOS,
	output signed [5:0] CRT_VSHIFT,
	output signed [5:0] CRT_VSIZE,
	output              CRT_VSMODE,
	output              CRT_VBL,
	output        [8:0] CRT_RD_BASE   // base del read-CE in ottavi: 64 nativo, 48 col CRT Rotate
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM: la usa solo screen_rotate (framebuffer della rotazione), in fondo al file
assign DDRAM_CLK = clk_sys;

// Le altre uscite FB_* le pilota screen_rotate in fondo al file; questa no,
// e senza un pilota resterebbe scollegata.
`ifdef MISTER_FB
assign FB_FORCE_BLANK = 0;
`ifdef MISTER_FB_PALETTE
assign {FB_PAL_CLK, FB_PAL_ADDR, FB_PAL_DOUT, FB_PAL_WR} = '0;
`endif
`endif

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 1'b0;  // overlay pause è renderizzato in real-time, no freeze scaler
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_USER  = 0;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

`include "build_id.v"
localparam CONF_STR = {
	"PowerSpikes;;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[21:19],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"P1O[22],Refresh Rate,Original,60Hz;",
	"H2P1O[8:7],Rotate,Off,CCW,CW;",
	"H2P1O[9],Flip 180,Off,On;",
	"P1O[91],CRT Adjust,Off,On;",
	"H1P1O[90:86],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[29:23],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[6:1],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[70:66],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[71],CRT V-Size Mode,PVM,Cabinet;",
	"H1H2P1O[73:72],CRT Rotate,Off,CCW,CW;",
	"H1H2P1O[74],CRT Rotate Fit,Fusion,Cut;",
	"H1H2H3P1O[80],CRT Rotate Camera,Fixed,Follow;",
	"H1H2H3H4P1O[79:75],CRT Rotate Cut Pos,0,+1,+2,+3,+4,+5,+6,+7,+8,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[35],Clean Pause,Off,On;",
	"O[10],User Port,Off,DB15 Joystick;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause;",
	"jn,A,B,X,Y,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [31:0] joy0_usb, joy1_usb, joy2, joy3;
reg  [31:0] joy0 = 32'd0, joy1 = 32'd0;   // P1/P2: USB oppure DB15 (blocco DB15 piu' in basso)

// Orientamento del set: lo dichiara la MRA (indice 1, byte 0, bit 0 = verticale).
// Dichiarato qui perche' serve gia' a hps_io per la menumask.
reg board_tate = 1'b0;

// Caricatore delle ROM dalla DDR attivo (rm_romload): serve gia' al reset.
wire ldr_on;
// Scrittura in SDRAM in corso nel download del core: serve a rm_romload e a ioctl_wait.
wire prog_we;

// Comandi della rotazione (da Asuka). Stanno qui e non accanto a screen_rotate
// perche' rotate_en serve anche all'aspect ratio, che viene prima nel file.
// status[8:7]: 00=Off, 01=CCW, 10=CW.  status[9] = Flip 180.
// Col CRT Rotate attivo (rot_act, dal core) il quadro esce gia' girato anche
// verso l'HDMI: il rotate del framebuffer si spegne, se no lo girerebbe due volte.
wire       rot_act;
wire [1:0] rotate_sel = (board_tate & ~rot_act) ? status[8:7] : 2'd0;
wire       rotate_en  = (rotate_sel != 2'd0);
wire       rotate_ccw = (rotate_sel == 2'd1);
wire       flip_180   = board_tate & ~rot_act & status[9];
wire       video_rotated;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;   // 8 bit (WIDE=0): il core prende i byte uno alla volta
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({11'd0, status[80], ~status[74], ~board_tate, ~status[91], 1'b0}),   // H1: voci CRT se CRT Adjust=Off; H2: rotazione sui set orizzontali; H3: camera e posizione del taglio solo col taglio; H4: posizione solo con la camera ferma
	.joystick_0(joy0_usb),
	.joystick_1(joy1_usb),
	.joystick_2(joy2),
	.joystick_3(joy3),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 57,272727 MHz: l'unico clock del core (il suo clk e clk48 sono lo stesso).
wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Game reset: includes download (game held in reset while ROM loads)
// + hold counter: tiene reset alto per ~2^17 cicli dopo che la causa cade,
// per dare tempo a SDRAM/PLL di stabilizzarsi.
wire reset_cause = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download | ldr_on;
reg [16:0] reset_hold_cnt = 17'h1FFFF;  // parte carico al power-on
always @(posedge clk_sys) begin
	if (reset_cause) reset_hold_cnt <= 17'h1FFFF;  // ricarica finche' c'e' causa
	else if (reset_hold_cnt != 17'd0) reset_hold_cnt <= reset_hold_cnt - 17'd1;
end
wire reset = (reset_hold_cnt != 17'd0);

// Pause: toggle sul fronte del tasto Pause del joypad (J1: joy[10]).
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[10] | joy1[10] | joy2[10] | joy3[10];
		if ((joy0[10] | joy1[10] | joy2[10] | joy3[10]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
wire pause = pause_toggle;
wire clean_pause = status[35]; // overlay off durante pausa

///////////////////////   DOWNLOAD -> CORE   ///////////////////////
// Il download lo fa il modello di memoria del core (jtframe_dwnld dentro
// jtpspike_game_sdram): rm_romload gli passa i byte dell'indice 0, da hps_io
// oppure, se la MRA chiede il caricamento in DDR (address=), dalla DDR.
wire [25:0] dl_addr;
wire        dl_rom, dl_wr;
wire  [7:0] dl_dout;
wire        ldr_ddr_rd;
wire [28:0] ldr_ddr_addr;
rm_romload #(.AW(26)) u_romload
(
	.clk            ( clk_sys          ),
	.ioctl_download ( ioctl_download   ),
	.ioctl_index    ( ioctl_index      ),
	.ioctl_wr       ( ioctl_wr         ),
	.ioctl_addr     ( ioctl_addr       ),
	.ioctl_dout     ( ioctl_dout       ),
	.prog_we        ( prog_we          ),
	.dl_rom         ( dl_rom           ),
	.dl_wr          ( dl_wr            ),
	.dl_addr        ( dl_addr          ),
	.dl_dout        ( dl_dout          ),
	.ldr_on         ( ldr_on           ),
	.ddr_rd         ( ldr_ddr_rd       ),
	.ddr_addr       ( ldr_ddr_addr     ),
	.ddr_busy       ( DDRAM_BUSY       ),
	.ddr_dout       ( DDRAM_DOUT       ),
	.ddr_dout_ready ( DDRAM_DOUT_READY )
);

// L'HPS aspetta finche' il core sta scrivendo in SDRAM (prog_we del core).
assign ioctl_wait = prog_we;

// DIP dalla MRA (indice 254): 4 byte -> dipsw del core.
reg [7:0] dsw[4];
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[24:2])
		dsw[ioctl_addr[1:0]] <= ioctl_dout;
wire [31:0] dipsw = {dsw[3], dsw[2], dsw[1], dsw[0]};

// Volume dalla MRA (indice 1, byte 1) -> snd_vol del core. Default 0x80.
reg [7:0] game_vol = 8'h80;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index[5:0] == 6'd1) && (ioctl_addr[1:0] == 2'd1))
		game_vol <= ioctl_dout;

// Orientamento dalla MRA (indice 1, byte 0): e' il core_mod di JTFRAME, il bit 0
// dice se il set e' verticale.
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index[5:0] == 6'd1) && (ioctl_addr[1:0] == 2'd0))
		board_tate <= ioctl_dout[0];

///////////////////////   INGRESSI   ///////////////////////////////
// ---- DB15 sulla porta utente (O[10]) ----------------------------------------
// joy_db15 (Aitor Pelaez, il lettore DB15 dei core MiSTer) + il mux che stava in
// jtframe_joymux: direzioni e tasti diretti, Start -> Start, Select -> Coin.
wire        db15_en = status[10];
wire [15:0] joydb15_1, joydb15_2;
wire        joy_db_clk, joy_db_load;
joy_db15 u_db15
(
	.clk       ( clk_sys     ),
	.JOY_CLK   ( joy_db_clk  ),
	.JOY_DATA  ( USER_IN[5]  ),
	.JOY_LOAD  ( joy_db_load ),
	.joystick1 ( joydb15_1   ),
	.joystick2 ( joydb15_2   )
);
assign USER_OUT = db15_en ? { 5'h1f, joy_db_clk, joy_db_load } : 7'h7f;
function [31:0] db15_map(input [15:0] db);
	db15_map      = 32'd0;
	db15_map[7:0] = db[7:0];
	db15_map[8]   = db[10];   // Start
	db15_map[9]   = db[11];   // Select -> Coin
endfunction
always @(posedge clk_sys) begin
	joy0 <= db15_en ? db15_map(joydb15_1) : joy0_usb;
	joy1 <= db15_en ? db15_map(joydb15_2) : joy1_usb;
end

// Il core legge i joypad attivi bassi: [0] su, [1] giu', [2] sinistra,
// [3] destra, [7:4] tasti 1-4. MiSTer: [0] destra, [1] sinistra, [2] giu',
// [3] su, tasti da [4]; Start = [8], Coin = [9] (ordine di J1).
function [7:0] joy_core(input [31:0] j);
	joy_core = ~{ j[7:4], j[0], j[1], j[2], j[3] };
endfunction
wire [3:0] cab_1p = ~{ joy3[8], joy2[8], joy1[8], joy0[8] };
wire [3:0] coin   = ~{ joy3[9], joy2[9], joy1[9], joy0[9] };

///////////////////////   CLOCK DEI PIXEL   ///////////////////////
// 57,27 / 8 = 7,159 MHz (pxl_cen) e / 4 (pxl2_cen), divisore intero.
wire pxl_cen, pxl2_cen;
reg [2:0] pxl_cnt = 3'd0;
reg       pxl_cen_r = 1'b0, pxl2_cen_r = 1'b0;
always @(posedge clk_sys) begin
	pxl_cnt    <= pxl_cnt + 3'd1;
	pxl2_cen_r <= (pxl_cnt[1:0] == 2'd3);
	pxl_cen_r  <= (pxl_cnt == 3'd7);
end
assign pxl_cen  = pxl_cen_r;
assign pxl2_cen = pxl2_cen_r;

///////////////////////   CORE (Andrea Bogazzi)   ///////////////////
// jtpspike_game_sdram: gioco + RAM + slot ROM + download + clock enable + mix.
wire  [4:0] red, green, blue;
wire        LHBL, LVBL, HS, VS;
wire signed [15:0] snd;
wire        sample, snd_peak;
wire  [5:0] snd_vu;
wire        dip_flip;
wire  [7:0] st_dout, debug_view;
wire        dwnld_busy;
wire [15:0] data_read;

wire [21:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire  [3:0] ba_rd, ba_wr, ba_dst, ba_dok, ba_rdy, ba_ack;
wire [15:0] ba0_din, ba1_din, ba2_din, ba3_din;
wire  [1:0] ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;

wire [21:0] prog_addr;
wire [15:0] prog_data;
wire  [1:0] prog_ba, prog_mask;
wire        prog_rd, prog_rdy, prog_ack, prog_dst, prog_dok;   // prog_we e' dichiarato in testa

// CRT Rotate (rm, jtpspike_video_rot): il gioco verticale esce gia' girato per il
// CRT orizzontale, a 15 kHz, senza quadro in memoria. Acceso con CRT Adjust, senza
// scandoubler e solo sui set verticali (la voce e' nascosta altrimenti, H1 e H2).
// status[73:72]: 00 Off, 01 CCW, 10 CW; CCW per primo perche' i giochi sono
// ROT270 in MAME, come nel Rotate dell'HDMI. Il core cambia modo a fine quadro.
wire [1:0] crt_rot_sel = (status[91] & ~forced_scandoubler & board_tate) ? status[73:72] : 2'd0;
// Fit: Fusion = tutte le colonne del gioco nelle righe del tubo, fuse in luce;
// Cut = una colonna per riga, 1:1, con la finestra spostabile (status[79:75]:
// indice della lista 0,+1..+8,-8..-1 -> scatti di 8 colonne con segno).
wire       crt_rot_cut = status[74];
wire [4:0] crt_cut_idx = status[79:75];
wire [4:0] crt_cut_pos = (crt_cut_idx <= 5'd8)  ? crt_cut_idx
                       : (crt_cut_idx <= 5'd16) ? (crt_cut_idx - 5'd17)   // 9..16 -> -8..-1
                       : 5'd0;
// Camera (status[80]): Fixed = finestra alla posizione del menu; Follow = la
// finestra segue le navi (camera di Darius rework, vedi jtpspike_video_rot).
wire       crt_rot_follow = status[80];
wire [7:0] rot_r, rot_g, rot_b;
wire       rot_ce, rot_hb, rot_vb, rot_vs;
// rm_rot_cam: navi e scritte dal bus del 68000 (fuori dal core di Andrea)
wire [19:1]  tap_addr;
wire         tap_cs;
wire [15:0]  tap_dout;
wire [ 1:0]  tap_ram_we, tap_oram_we;
wire [10:1]  tap_oram_addr;
wire [15:0]  cam_x0, cam_x1, cam_x2;
wire [ 2:0]  cam_on;
wire [127:0] rot_hud;

jtpspike_game_sdram u_game
(
	.rst        ( reset         ),
	.clk        ( clk_sys       ),
	.rst24      ( reset         ),
	.clk24      ( clk_sys       ),
	.rst48      ( reset         ),
	.clk48      ( clk_sys       ),
	.rst96      ( reset         ),
	.clk96      ( clk_sys       ),
	.pxl2_cen   ( pxl2_cen      ),
	.pxl_cen    ( pxl_cen       ),
	.red        ( red           ),
	.green      ( green         ),
	.blue       ( blue          ),
	.LHBL       ( LHBL          ),
	.LVBL       ( LVBL          ),
	.HS         ( HS            ),
	.VS         ( VS            ),
	// cabinet I/O
	.cab_1p     ( cab_1p        ),
	.coin       ( coin          ),
	.joystick1  ( joy_core(joy0) ),
	.joystick2  ( joy_core(joy1) ),
	.joystick3  ( joy_core(joy2) ),
	.joystick4  ( joy_core(joy3) ),
	.dial_x     ( 2'd0          ),
	.dial_y     ( 2'd0          ),
	.joyana_l1  ( 16'd0 ), .joyana_l2 ( 16'd0 ), .joyana_l3 ( 16'd0 ), .joyana_l4 ( 16'd0 ),
	.joyana_r1  ( 16'd0 ), .joyana_r2 ( 16'd0 ), .joyana_r3 ( 16'd0 ), .joyana_r4 ( 16'd0 ),
	// Sound control
	.snd_en     ( 6'h3f         ),
	.snd_vol    ( game_vol      ),
	// DIP switches
	.status     ( 32'd0         ),
	.dipsw      ( dipsw         ),
	.dip_pause  ( ~pause        ),   // attivo basso: sul 68000 e' HALTn
	.dip_test   ( 1'b1          ),
	.service    ( 1'b1          ),
	.tilt       ( 1'b1          ),
	.dip_flip   ( dip_flip      ),
	.dip_fxlevel( 2'b10         ),
	// Debug
	.st_addr    ( 8'd0          ),
	.st_dout    ( st_dout       ),
	.gfx_en     ( 4'hf          ),
	.debug_bus  ( 8'd0          ),
	.debug_view ( debug_view    ),
	// ROM download
	.ioctl_addr ( dl_addr       ),
	.ioctl_dout ( dl_dout       ),
	.ioctl_wr   ( dl_wr         ),
	.ioctl_rom  ( dl_rom        ),
	.ioctl_ram  ( 1'b0          ),
	.dwnld_busy ( dwnld_busy    ),
	.data_read  ( data_read     ),
	.ioctl_cart ( 1'b0          ),
	// SDRAM
	.ba0_addr   ( ba0_addr      ),
	.ba1_addr   ( ba1_addr      ),
	.ba2_addr   ( ba2_addr      ),
	.ba3_addr   ( ba3_addr      ),
	.ba_rd      ( ba_rd         ),
	.ba_wr      ( ba_wr         ),
	.ba_dst     ( ba_dst        ),
	.ba_dok     ( ba_dok        ),
	.ba_rdy     ( ba_rdy        ),
	.ba_ack     ( ba_ack        ),
	.ba0_din    ( ba0_din       ),
	.ba1_din    ( ba1_din       ),
	.ba2_din    ( ba2_din       ),
	.ba3_din    ( ba3_din       ),
	.ba0_dsn    ( ba0_dsn       ),
	.ba1_dsn    ( ba1_dsn       ),
	.ba2_dsn    ( ba2_dsn       ),
	.ba3_dsn    ( ba3_dsn       ),
	.prog_data  ( prog_data     ),
	.prog_rdy   ( prog_rdy      ),
	.prog_ack   ( prog_ack      ),
	.prog_dst   ( prog_dst      ),
	.prog_dok   ( prog_dok      ),
	.prog_ba    ( prog_ba       ),
	.prog_we    ( prog_we       ),
	.prog_rd    ( prog_rd       ),
	.prog_mask  ( prog_mask     ),
	.prog_addr  ( prog_addr     ),
	// Sound output
	.snd        ( snd           ),
	.snd_vu     ( snd_vu        ),
	.snd_peak   ( snd_peak      ),
	.sample     ( sample        ),
	// CRT Rotate
	.rot_req    ( crt_rot_sel != 2'd0 ),
	.rot_ccw_req( crt_rot_sel == 2'd1 ),
	.rot_cut_req( crt_rot_cut   ),
	.rot_pos_req( crt_cut_pos   ),
	.rot_follow_req( crt_rot_follow ),
	// Refresh Rate (status[22]): Original = totali del GGA scritti dal gioco
	// (Turbo Force 61,3 Hz, Aero Fighters 62,8 Hz); 60Hz = quadro di 262 righe,
	// 59,92 Hz, righe in piu' in vblank (come il V_TOTAL dei core rm). Il gioco
	// va al ritmo del quadro: -2,2% / -4,6%.
	.refresh60  ( status[22]    ),
	.cam_x0     ( cam_x0        ),
	.cam_x1     ( cam_x1        ),
	.cam_x2     ( cam_x2        ),
	.cam_on     ( cam_on        ),
	.rot_hud    ( rot_hud       ),
	.tap_addr   ( tap_addr      ),
	.tap_cs     ( tap_cs        ),
	.tap_dout   ( tap_dout      ),
	.tap_ram_we ( tap_ram_we    ),
	.tap_oram_we( tap_oram_we   ),
	.tap_oram_addr( tap_oram_addr ),
	.rot_act    ( rot_act       ),
	.rot_r      ( rot_r         ),
	.rot_g      ( rot_g         ),
	.rot_b      ( rot_b         ),
	.rot_ce     ( rot_ce        ),
	.rot_hb     ( rot_hb        ),
	.rot_vb     ( rot_vb        ),
	.rot_vs     ( rot_vs        )
);

// Navi per la camera e scritte da spostare col taglio, gioco per gioco
// (debug_view: bit1 turbofrc, bit2 aerofgt, dall header della ROM)
rm_rot_cam u_rot_cam(
	.rst        ( reset         ),
	.clk        ( clk_sys       ),
	.turbofrc   ( debug_view[1] ),
	.aerofgt    ( debug_view[2] ),
	.main_addr  ( tap_addr      ),
	.main_cs    ( tap_cs        ),
	.main_dout  ( tap_dout      ),
	.ram_we     ( tap_ram_we    ),
	.oram_we    ( tap_oram_we   ),
	.oram_addr  ( tap_oram_addr ),
	.cam_x0     ( cam_x0        ),
	.cam_x1     ( cam_x1        ),
	.cam_x2     ( cam_x2        ),
	.cam_on     ( cam_on        ),
	.hud        ( rot_hud       )
);

// Controller SDRAM del core (jtframe_board_sdram -> jtframe_sdram64).
reg prog_en = 1'b0;
always @(posedge clk_sys) prog_en <= dwnld_busy;

jtframe_board_sdram #(.SDRAMW(22), .MISTER(1)) u_sdram
(
	.rst        ( ~pll_locked   ),
	.clk        ( clk_sys       ),
	.init       (               ),
	.prog_en    ( prog_en       ),

	.ba0_addr   ( ba0_addr      ),
	.ba1_addr   ( ba1_addr      ),
	.ba2_addr   ( ba2_addr      ),
	.ba3_addr   ( ba3_addr      ),
	.burst_addr ( 22'd0         ),
	.burst_ba   ( 2'd0          ),
	.burst_rd   ( 1'b0          ),
	.burst_wr   ( 1'b0          ),
	.ba_rd      ( ba_rd         ),
	.ba_wr      ( ba_wr         ),
	.ba0_din    ( ba0_din       ),
	.ba0_dsn    ( ba0_dsn       ),
	.ba1_din    ( ba1_din       ),
	.ba1_dsn    ( ba1_dsn       ),
	.ba2_din    ( ba2_din       ),
	.ba2_dsn    ( ba2_dsn       ),
	.ba3_din    ( ba3_din       ),
	.ba3_dsn    ( ba3_dsn       ),
	.burst_din  ( 16'd0         ),
	.burst_ack  (               ),
	.burst_rdy  (               ),
	.burst_dst  (               ),
	.burst_dok  (               ),
	.ba_ack     ( ba_ack        ),
	.ba_rdy     ( ba_rdy        ),
	.ba_dst     ( ba_dst        ),
	.ba_dok     ( ba_dok        ),
	.dout       ( data_read     ),

	.prog_addr  ( prog_addr     ),
	.prog_data  ( prog_data     ),
	.prog_dsn   ( prog_mask     ),
	.prog_ba    ( prog_ba       ),
	.prog_we    ( prog_we       ),
	.prog_rd    ( prog_rd       ),
	.prog_dok   ( prog_dok      ),
	.prog_rdy   ( prog_rdy      ),
	.prog_dst   ( prog_dst      ),
	.prog_ack   ( prog_ack      ),

	.sdram_dq   ( SDRAM_DQ      ),
	.sdram_a    ( SDRAM_A       ),
	.sdram_dqml ( SDRAM_DQML    ),
	.sdram_dqmh ( SDRAM_DQMH    ),
	.sdram_nwe  ( SDRAM_nWE     ),
	.sdram_ncas ( SDRAM_nCAS    ),
	.sdram_nras ( SDRAM_nRAS    ),
	.sdram_ncs  ( SDRAM_nCS     ),
	.sdram_ba   ( SDRAM_BA      ),
	.sdram_cke  ( SDRAM_CKE     )
);

// SDRAM_CLK driven via altddio_out (180° shift) — pattern identico a Sorgelig.
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_sys),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

///////////////////////   AUDIO   ///////////////////////////////
assign AUDIO_S   = 1;  // signed audio
assign AUDIO_L   = snd;
assign AUDIO_R   = snd;
assign AUDIO_MIX = 0;

///////////////////////   VIDEO   ///////////////////////////////

// Col CRT Rotate (rot_act) esce il raster girato del core (jtpspike_video_rot):
// pixel a 57,27/6, gli stessi HSync e la stessa lunghezza di riga del gioco, le
// stesse righe per quadro, VSync alla riga 0 del gioco. Il gioco resta sul suo
// VBlank: qui si commuta solo il video.
wire HBlank = rot_act ? rot_hb : ~LHBL;
wire VBlank = rot_act ? rot_vb : ~LVBL;
wire ce_pix = rot_act ? rot_ce : pxl_cen;
wire vid_vs = rot_act ? rot_vs : VS;
wire vid_lhbl = ~HBlank;
wire vid_lvbl = ~VBlank;
wire [7:0] video_r = rot_act ? rot_r : {red,   red[4:2]};
wire [7:0] video_g = rot_act ? rot_g : {green, green[4:2]};
wire [7:0] video_b = rot_act ? rot_b : {blue,  blue[4:2]};

assign CLK_VIDEO = clk_sys;
// CE_PIXEL nativo: la regolazione CRT e' in sys_top (sys-side).

// Coordinate del pixel per il pause overlay. NUOVO: il core porta solo i blank.
// render_x = pixel attivi dall'inizio riga, render_y = righe attive dall'inizio
// quadro; durante il primo pixel/la prima riga attivi valgono 0.
reg [9:0] render_x = 10'd0;
reg [8:0] render_y = 9'd0;
reg       lhbl_l = 1'b0;
always @(posedge clk_sys) if (ce_pix) begin
	lhbl_l   <= vid_lhbl;
	render_x <= vid_lhbl ? render_x + 10'd1 : 10'd0;
	if (!vid_lvbl)                render_y <= 9'd0;
	else if (lhbl_l && !vid_lhbl) render_y <= render_y + 9'd1;   // fine di una riga attiva
end

// Misure del quadro attivo per il pause overlay (NUOVO): il GGA lo programma il
// gioco (Power Spikes, Karate Blazers, Turbo Force 352x240; Aero Fighters
// 320x224). A fine riga render_x vale i pixel attivi; la riga conta se LVBL era
// alto mentre scorreva (lvbl_l): il GGA abbassa LVBL sullo stesso fronte di LHBL,
// e cosi' l'ultima riga entra lo stesso.
reg       lvbl_l    = 1'b0;
reg [8:0] act_lines = 9'd0;
reg [9:0] scr_w     = 10'd352;
reg [8:0] scr_h     = 9'd240;
always @(posedge clk_sys) if (ce_pix) begin
	lvbl_l <= vid_lvbl;
	if (lhbl_l && !vid_lhbl && lvbl_l) begin
		scr_w     <= render_x;
		act_lines <= act_lines + 9'd1;
	end
	if (!lvbl_l && vid_lvbl) begin                           // inizio del campo attivo
		scr_h     <= act_lines;
		act_lines <= 9'd0;
	end
end

// ── CRT Adjust (Analog H-Size + H-Position + V-Shift) — modulo unico ─────────
// ON/OFF (status[91]): OFF = bypass nativo puro, ON = modulo attivo.
// REGOLA 6 (doc 17): con scandoubler o scaler attivi il CE raddoppia e la base
// del generatore di lettura non vale piu' -> garbage. Off forzato.
reg crt_on;
always @(posedge clk_sys) if (ce_pix)
	crt_on <= status[91] & ~forced_scandoubler;   // lo Scale (status[21:19]) e' solo integer scaling HDMI: non tocca l'analogico

// H-Size bidirezionale (status[90:86], two's complement 5-bit -16..+15).
reg signed [4:0] hsize_s;
always @(posedge clk_sys) if (ce_pix) hsize_s <= $signed(status[90:86]);

// H-Position (status[29:23], 7 bit): 0..48 = +0..+48 (destra), resto = negativo.
reg [6:0] hpos_d;
always @(posedge clk_sys) if (ce_pix) hpos_d <= status[29:23];
// Il menu salva l'INDICE nella lista: 97 voci (0, +1..+48, -48..-1). Il wrap va
// fatto sulla LUNGHEZZA DELLA LISTA: con -128 la voce "-1" valeva -32 px e da 0
// a -1 l'immagine SALTAVA di 32 pixel (bug citato nel doc 17).
wire signed [8:0] hpos_off = (hpos_d <= 7'd48)
	? $signed({2'b0, hpos_d})
	: $signed({2'b0, hpos_d}) - 9'sd97;

// V-Shift (status[6:1], signed 6-bit -32..+31 righe).
reg signed [5:0] vshift_off;
always @(posedge clk_sys) if (ce_pix) vshift_off <= $signed(status[6:1]);

// Il generatore del read-CE e' in sys_top (variante sys-side).

// Pause overlay (da Night Slashers): logo centrato + header "A core by Andrea
// Bogazzi" + patron scroll. Clean Pause (status[35]) = bypass overlay dentro il modulo.
wire [7:0] av_r, av_g, av_b;
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (pause),
	.clean     (clean_pause),
	.vblank    (VBlank),
	// verticale: overlay ruotato come negli altri core; col CRT Rotate il quadro
	// esce gia' dritto e l'overlay si disegna dritto sulle sue misure
	.tate      (board_tate & ~rot_act),
	.scr_w     (scr_w),
	.scr_h     (scr_h),
	// fuori dall'area attiva 900: fuori da ogni riquadro, anche ruotato (da Asuka)
	.render_x_in ((vid_lhbl & vid_lvbl) ? render_x : 10'd900),
	.render_y_in (render_y),
	.rgb_r_in  (video_r),
	.rgb_g_in  (video_g),
	.rgb_b_in  (video_b),
	.rgb_r_out (av_r),
	.rgb_g_out (av_g),
	.rgb_b_out (av_b)
);

// -- Valori CRT esportati a sys_top (variante SYS-SIDE) ----------------------
// I due moduli vivono in sys/ fra scanlines e vga_osd: qui restano solo il
// decode dell'OSD e il VBlank vero. Cosi' l'HDMI resta bit-identico mentre si
// regola il CRT, che e' il motivo per cui questa variante esiste.
// Il modulo usa +N = immagine piu' BASSA, quindi si nega: il "+" dell'OSD vuol
// dire piu' ALTA, coerente con l'H-Size. Campo OSD a complemento a due.
//  PVM (retimer): 1 riga per scatto. Cabinet (ottico): 3 righe per scatto.
//  Corsa calcolata sul raster del core, per modo (doc 17 §2bis). Dati dalle
//  tabelle GGA dei giochi: riga 456 px x 8 clk, quadro 256 righe (Aero
//  Fighters 250), attive 240 (224), VSync 4 righe.
//  PVM: f = 256*456*8 = 933.888 clk; righe fra ceil(f/3788) = 247 e
//    floor(f/3536) = 264 -> vsize -9..+8 (Aero Fighters -9..+7: il resto lo
//    tiene il modulo, che misura f da solo).
//  Cabinet: allargare senza perdere righe fino a 9 (Aero Fighters 19: si tiene
//    il piu' stretto); stringere fino al ring, |vsize| <= 32/2 - 2 = 14.
//  Refresh Rate 60Hz (262 righe): PVM f = 955.776 clk, righe 253..270 = di nuovo
//    -9..+8; Cabinet ha 6-12 righe di vblank in piu': i limiti restano validi.
wire signed [5:0] vsz_step  = $signed(status[70:66]);
wire signed [7:0] vsz_ext   = {{2{vsz_step[5]}}, vsz_step};
wire signed [7:0] vsz_pvm_r = -vsz_ext;
wire signed [7:0] vsz_cab_r = -(vsz_ext + (vsz_ext <<< 1));
wire signed [7:0] vsz_req   = status[71] ? vsz_cab_r : vsz_pvm_r;
wire signed [7:0] vsz_min   = -8'sd9;                             // PVM e Cabinet
wire signed [7:0] vsz_max   = status[71] ? 8'sd14 : 8'sd8;        // Cabinet : PVM
wire signed [7:0] vsz_lim   = (vsz_req < vsz_min) ? vsz_min
                            : (vsz_req > vsz_max) ? vsz_max : vsz_req;
wire signed [5:0] vsz_lines = vsz_lim[5:0];
reg  signed [5:0] crt_vsize_d;
reg               crt_vsmode_d;
always @(posedge clk_sys) if (ce_pix) begin
	crt_vsize_d  <= crt_on ? vsz_lines : 6'sd0;
	crt_vsmode_d <= status[71];
end

assign CRT_ON     = crt_on;
assign CRT_HSIZE  = hsize_s;
assign CRT_HPOS   = hpos_off;
assign CRT_VSHIFT = vshift_off;
assign CRT_VSIZE  = crt_vsize_d;
assign CRT_VSMODE = crt_vsmode_d;
assign CRT_VBL    = VBlank;        // VBlank VERO di quello che esce, mai il blank combinato
// Base del read-CE in ottavi di clk: pixel nativo 8 clk -> 64; CRT Rotate 6 clk -> 48
assign CRT_RD_BASE = rot_act ? 9'd48 : 9'd64;

// Uscite native: la regolazione avviene in sys_top, a valle.
assign VGA_HS   = HS;
assign VGA_VS   = vid_vs;
assign VGA_R    = av_r;
assign VGA_G    = av_g;
assign VGA_B    = av_b;
assign CE_PIXEL = ce_pix;

// Aspect ratio: Original = 4:3, Full Screen = 0:0
// Con la rotazione accesa l'immagine diventa verticale: l'aspect va scambiato,
// altrimenti resta 4:3 su un'immagine 3:4 (da Asuka).
// Col CRT Rotate il quadro esce gia' girato (verticale): anche li' 3:4.
wire [11:0] arx = (!ar) ? ((rotate_en | rot_act) ? 12'd3 : 12'd4) : (ar - 1'd1);
wire [11:0] ary = (!ar) ? ((rotate_en | rot_act) ? 12'd4 : 12'd3) : 12'd0;

// Integer scaling (Scale menu: Normal / V-Integer / Narrower HV-Integer)
// video_freak misura il video del core NON ruotato. Con la rotazione lo scaler
// riceve il framebuffer girato: l'intero va calcolato sulle sue misure, che
// screen_rotate da' gia' (FB_WIDTH = righe del core, FB_HEIGHT = pixel della
// riga). Senza, l'"intero" non lo e' (Turbo Force 352x240 a 1080p: 960/352 = 2,73).
wire [12:0] vf_arx, vf_ary, rot_arx, rot_ary;
assign VIDEO_ARX = rotate_en ? rot_arx : vf_arx;
assign VIDEO_ARY = rotate_en ? rot_ary : vf_ary;

video_scale_int rot_scale
(
	.CLK_VIDEO  (clk_sys),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.SCALE      (status[21:19]),
	.hsize      (FB_WIDTH),
	.vsize      (FB_HEIGHT),
	.arx_i      (arx),
	.ary_i      (ary),
	.arx_o      (rot_arx),
	.ary_o      (rot_ary)
);

video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(ce_pix),
	.VGA_VS(vid_vs),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(vf_arx),
	.VIDEO_ARY(vf_ary),
	.VGA_DE_IN(~(HBlank | VBlank)),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[21:19])   // 0=Normal 1=V-Int 2=Narrower 3=Wider 4=HV-Integer
);

// ============================================================
// Rotazione schermo (TATE) — da Asuka
// ============================================================
// screen_rotate annusa VGA_* a CLK_VIDEO e scrive il framebuffer ruotato in
// DDR3 a 0x24000000 (MEM_BASE). La DDR e' sua, tranne mentre il caricatore
// ripassa al core le ROM che il MiSTer ha messo a 0x30000000: allora i pin vanno
// al caricatore. In Asuka/Raiden passa da una FIFO e da un arbitro perche' li'
// anche il gioco usa la DDR. La rotazione HDMI la fa screen_rotate col framebuffer HPS,
// NON dirottando l'uscita analogica: il CRT non cambia percorso quando accendi
// il rotate. Per questo video_rotated resta volutamente non usato.
// Le voci sono nascoste (H2) sui set orizzontali.

wire  [7:0] rot_burstcnt;
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
wire        rot_we, rot_rd;
assign DDRAM_BURSTCNT = ldr_on ? 8'd1   : rot_burstcnt;
assign DDRAM_ADDR     = ldr_on ? ldr_ddr_addr : rot_addr;
assign DDRAM_DIN      = ldr_on ? 64'd0  : rot_din;
assign DDRAM_BE       = ldr_on ? 8'hFF  : rot_be;
assign DDRAM_WE       = ldr_on ? 1'b0   : rot_we;
assign DDRAM_RD       = ldr_on ? ldr_ddr_rd : rot_rd;

screen_rotate u_screen_rotate
(
	.CLK_VIDEO     (clk_sys),
	.CE_PIXEL      (ce_pix),

	.VGA_R         (VGA_R),
	.VGA_G         (VGA_G),
	.VGA_B         (VGA_B),
	.VGA_HS        (VGA_HS),
	.VGA_VS        (VGA_VS),
	.VGA_DE        (VGA_DE),

	.rotate_ccw    (rotate_ccw),
	.no_rotate     (~rotate_en),
	.flip          (flip_180),
	.video_rotated (video_rotated),

	.FB_EN         (FB_EN),
	.FB_FORMAT     (FB_FORMAT),
	.FB_WIDTH      (FB_WIDTH),
	.FB_HEIGHT     (FB_HEIGHT),
	.FB_BASE       (FB_BASE),
	.FB_STRIDE     (FB_STRIDE),
	.FB_VBL        (FB_VBL),
	.FB_LL         (FB_LL),

	.DDRAM_CLK     (),
	.DDRAM_BUSY    (DDRAM_BUSY | ldr_on),
	.DDRAM_BURSTCNT(rot_burstcnt),
	.DDRAM_ADDR    (rot_addr),
	.DDRAM_DIN     (rot_din),
	.DDRAM_BE      (rot_be),
	.DDRAM_WE      (rot_we),
	.DDRAM_RD      (rot_rd)
);

endmodule
