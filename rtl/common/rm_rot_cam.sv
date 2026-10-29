/*  rmPowerSpikes - CRT Rotate in Cut: quello che dipende dal programma dei
    giochi, fuori dal core di Andrea.

    Author: Umberto Parisi (rmonic79)
    Date: 2026
*/

// rm_rot_cam guarda il bus del 68000 (fili esportati da jtpspike_game_sdram, tutti
// su clk_sys) e dice al renderer a colonne:
//   1. dove sono le navi, per la camera (Follow);
//   2. quali posti sprite del chip 1 sono scritte a posizione fissa (punteggio,
//      INSERT COIN, CREDIT): nel taglio il renderer le sposta con la finestra.
// Indirizzi e conti dall analisi statica dei programmi (Turbo Force e Aero
// Fighters); sugli altri giochi le uscite restano a zero.
//
// NAVI. Si tengono le parole delle navi, byte per byte come le scrive la CPU.
// Turbo Force: oggetti giocatore a 0c1f6e + $68*p, X in +$e (0c1f7c, 0c1fe4,
//   0c204c). In gioco = bit p di 0c331b (byte basso della parola 0c331a):
//   messo quando la nave prende i comandi (0041e8), tolto alla morte (007810).
//   Sprite della nave: X + $fd00 + 8 (9 bit), 32 colonne; X fermata in
//   $30e..$436 = colonne 22..349 di 352. Centro = X - 744.
// Aero Fighters: oggetti giocatore a 0c06c0 / 0c0720, X in +$10 (0c06d0,
//   0c0730). In gioco = byte 0c06c0 / 0c0720 diverso da 0 (byte alto): il bit 7
//   lampeggia con l invulnerabilita' ma il byte resta acceso, si spegne a fine
//   partita del giocatore. Sprite: X - 16 + 9, 32 colonne per tutti gli aerei e
//   le inclinazioni; il renderer legge la colonna x all indirizzo x + 10.
//   Centro = X - 1.
// Colonne senza flip, con segno; col flip il renderer usa W-1-colonna.
//
// SCRITTE. In tutti e due i giochi la lista del chip 1 si costruisce in RAM e a
// ogni quadro la copia nella sprite RAM mette la voce k al posto 126-k (copia
// all indietro da 0fc7f0) e chiude scrivendo il primo posto in 0fc7fc: in quel
// momento la maschera dei posti si fissa, insieme alla sprite RAM che il
// renderer leggera'.
// Turbo Force: le scritte (0011e2-0016d4, 002a08, oggetto della scritta
//   00678x-006d22 per ogni giocatore) chiamano il costruttore del gruppo "a"
//   entrando direttamente in 002cd2 con le coordinate gia' caricate; gli oggetti
//   (le navi) entrano in 002cca e arrivano a 002cd2 dopo 002cd0. Quindi:
//   accesso alla ROM a 002cd2 non preceduto da 002cd0 = scritta. Le voci del
//   gruppo "a" stanno a 0c10e0 + 8k, il loro numero in 0c1e1c (copia 002dba).
// Aero Fighters: le scritte sono gli oggetti 2..7 della tabella (0c00c0..0c02ff:
//   controllore per giocatore a X = Y = 0, tipi 3-6). Il costruttore (01c016)
//   legge il primo byte di ogni oggetto in ordine da 0c0000: letto 0c00c0 si e'
//   nelle scritte, letti 0c0300 o 0c0000 no. Voci a 0c7400 + 8k, numero in
//   0c8d04 (copia 000f4e).
module rm_rot_cam(
	input              rst,
	input              clk,
	input              turbofrc,
	input              aerofgt,
	// bus del 68000
	input       [19:1] main_addr,
	input              main_cs,      // lettura della ROM di programma
	input       [15:0] main_dout,
	input       [ 1:0] ram_we,       // RAM di lavoro 0c0000-0cffff: {byte alto, byte basso}
	input       [ 1:0] oram_we,      // sprite RAM 0fc000-0fc7ff
	input       [10:1] oram_addr,
	// navi
	output reg  [15:0] cam_x0, cam_x1, cam_x2,   // colonna del centro delle navi
	output reg  [ 2:0] cam_on,                   // navi in gioco
	// scritte: un bit per posto sprite del chip 1
	output reg [127:0] hud
);

wire [15:1] a    = main_addr[15:1];
wire        game = turbofrc | aerofgt;

// ---------------- navi ----------------
reg  [15:0] xw0, xw1, xw2, pw0, pw1;
wire [15:1] ax0  = turbofrc ? 15'h0fbe : 15'h0368;   // 0c1f7c / 0c06d0
wire [15:1] ax1  = turbofrc ? 15'h0ff2 : 15'h0398;   // 0c1fe4 / 0c0730
wire [15:1] ax2  = 15'h1026;                         // 0c204c, solo Turbo Force
wire [15:1] ap0  = turbofrc ? 15'h198d : 15'h0360;   // 0c331a / 0c06c0
wire [15:1] ap1  = 15'h0390;                         // 0c0720, solo Aero Fighters
wire [15:0] koff = turbofrc ? 16'hfd18 : 16'hffff;   // -744 / -1

always @(posedge clk) begin
	if (rst) begin
		xw0 <= 16'd0; xw1 <= 16'd0; xw2 <= 16'd0;
		pw0 <= 16'd0; pw1 <= 16'd0;
	end else begin
		if (a == ax0) begin
			if (ram_we[1]) xw0[15:8] <= main_dout[15:8];
			if (ram_we[0]) xw0[ 7:0] <= main_dout[ 7:0];
		end
		if (a == ax1) begin
			if (ram_we[1]) xw1[15:8] <= main_dout[15:8];
			if (ram_we[0]) xw1[ 7:0] <= main_dout[ 7:0];
		end
		if (a == ax2) begin
			if (ram_we[1]) xw2[15:8] <= main_dout[15:8];
			if (ram_we[0]) xw2[ 7:0] <= main_dout[ 7:0];
		end
		if (a == ap0) begin
			if (ram_we[1]) pw0[15:8] <= main_dout[15:8];
			if (ram_we[0]) pw0[ 7:0] <= main_dout[ 7:0];
		end
		if (a == ap1) begin
			if (ram_we[1]) pw1[15:8] <= main_dout[15:8];
			if (ram_we[0]) pw1[ 7:0] <= main_dout[ 7:0];
		end
	end
	cam_x0 <= xw0 + koff;
	cam_x1 <= xw1 + koff;
	cam_x2 <= xw2 + koff;
	cam_on <= turbofrc ? pw0[2:0] : aerofgt ? {1'b0, |pw1[15:8], |pw0[15:8]} : 3'd0;
end

// ---------------- scritte ----------------
// Turbo Force: ultimo accesso alla ROM e da dove si e' entrati in 002cd2
reg  [19:1] ra_l, ra_cur;
reg         cs_l, tf_txt;
wire        ra_new = main_cs && (!cs_l || (main_addr != ra_l));

// Aero Fighters: il costruttore sta lavorando gli oggetti 2..7
reg         af_txt;
wire        ram_a  = (main_addr[19:16] == 4'hc);

// voci della lista
wire        tf_lst = (a >= 15'h0870) && (a < 15'h09b0);         // 0c10e0-0c135f
wire [14:0] tf_off = a - 15'h0870;
wire        af_lst = (a >= 15'h3a00) && (a < 15'h3c00);         // 0c7400-0c77ff
wire [14:0] af_off = a - 15'h3a00;
wire [ 6:0] lst_k  = turbofrc ? tf_off[8:2] : af_off[8:2];
wire        lst_in = turbofrc ? tf_lst : af_lst;
wire        lst_t  = turbofrc ? tf_txt : af_txt;
wire [15:1] cnt_a  = turbofrc ? 15'h0f0e : 15'h4682;            // 0c1e1c / 0c8d04

reg [127:0] tag;
reg [  7:0] cnt;
integer     k;

always @(posedge clk) begin
	cs_l <= main_cs;
	ra_l <= main_addr;
	if (rst) begin
		ra_cur <= 19'd0;
		tf_txt <= 1'b0;
		af_txt <= 1'b0;
		tag    <= 128'd0;
		cnt    <= 8'd0;
		hud    <= 128'd0;
	end else begin
		if (ra_new) begin
			ra_cur <= main_addr;
			if (main_addr == 19'h01669) tf_txt <= (ra_cur != 19'h01668);   // 002cd2, 002cd0
		end
		if (ram_a) begin
			if (a == 15'h0000 || a == 15'h0180) af_txt <= 1'b0;          // oggetti 0 e 8
			else if (a == 15'h0060)              af_txt <= 1'b1;          // oggetto 2
		end
		if (|ram_we) begin
			if (lst_in)    tag[lst_k] <= lst_t;
			if (a == cnt_a && ram_we[0]) cnt <= main_dout[7:0];
		end
		if (|oram_we && oram_addr == 10'h3fe) begin                         // 0fc7fc
			for (k = 0; k < 127; k = k + 1)
				hud[126-k] <= game && tag[k] && (k < cnt);
			hud[127] <= 1'b0;
		end
	end
end

endmodule
