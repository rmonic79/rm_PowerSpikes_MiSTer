// SPDX-License-Identifier: GPL-3.0-or-later
/*  rm_romload — download delle ROM verso un core JTFRAME (interfaccia rm).
    GPL-3. Umberto Parisi (rmonic79).

    Passa al download del core (jtframe_dwnld) i byte dell'indice 0:
    - da hps_io (MRA senza address=), con un registro;
    - dalla DDR (MRA con address=). Il Main (mra_loader.cpp, rom_finish) fa
      set_download(1, len) -> len finisce in ioctl_addr; poi shmem_put scrive le
      ROM in DDR all'indirizzo della MRA; poi set_download(0). Nessun ioctl_wr in
      mezzo. Se il download dell'indice 0 si chiude senza byte, le ROM si
      rileggono dalla DDR e si passano al core un byte alla volta.
    Il core alza prog_we 2 cicli dopo il byte e lo riabbassa quando la SDRAM
    accetta (regge una sola scrittura in coda): dopo ogni byte si aspettano 3
    cicli e poi prog_we basso. I byte dell'header non scrivono in SDRAM.
*/

module rm_romload #(
	parameter       AW      = 26,      // larghezza di ioctl_addr del core
	parameter [3:0] ROM_DDR = 4'd3     // 0x30000000, l'address delle MRA di Andrea
)(
	input             clk,
	// hps_io
	input             ioctl_download,
	input      [15:0] ioctl_index,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	// download del core
	input             prog_we,
	output            dl_rom,
	output            dl_wr,
	output   [AW-1:0] dl_addr,
	output      [7:0] dl_dout,
	// DDR: lettura delle ROM (i pin sono suoi solo mentre ldr_on)
	output reg        ldr_on = 1'b0,
	output reg        ddr_rd = 1'b0,
	output     [28:0] ddr_addr,
	input             ddr_busy,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready
);

wire         dl0 = ioctl_download & (ioctl_index[5:0] == 6'd0);

// percorso hps_io: un registro
reg          hps_rom = 1'b0, hps_wr = 1'b0;
reg [AW-1:0] hps_addr = {AW{1'b0}};
reg    [7:0] hps_dout = 8'd0;
always @(posedge clk) begin
	hps_rom  <= dl0;
	hps_wr   <= ioctl_wr & (ioctl_index[5:0] == 6'd0);
	hps_addr <= ioctl_addr[AW-1:0];
	hps_dout <= ioctl_dout;
end

// percorso DDR
reg        rom_got = 1'b0;          // il download dell'indice 0 ha ricevuto byte
reg [26:0] rom_len = 27'd0;
reg        ldr_wr  = 1'b0;
reg [26:0] ldr_ptr = 27'd0;
reg [63:0] ldr_word = 64'd0;
reg  [2:0] ldr_st  = 3'd0;
reg  [1:0] ldr_gap = 2'd0;
always @(posedge clk) begin
	ldr_wr <= 1'b0;
	if (dl0) begin
		if (!hps_rom) rom_got <= 1'b0;
		if (ioctl_wr) rom_got <= 1'b1;
		rom_len <= ioctl_addr;                   // senza byte resta la lunghezza mandata dal Main
	end
	if (hps_rom && !dl0 && !rom_got && rom_len != 27'd0) begin
		ldr_on  <= 1'b1;
		ldr_ptr <= 27'd0;
		ldr_st  <= 3'd0;
	end else if (ldr_on) begin
		case (ldr_st)
			3'd0: if (ldr_ptr >= rom_len) ldr_on <= 1'b0;                      // finito
			      else begin ddr_rd <= 1'b1; ldr_st <= 3'd1; end               // chiede una parola
			3'd1: if (!ddr_busy) begin ddr_rd <= 1'b0; ldr_st <= 3'd2; end      // accettata
			3'd2: if (ddr_dout_ready) begin ldr_word <= ddr_dout; ldr_st <= 3'd3; end
			3'd3: begin ldr_wr <= 1'b1; ldr_gap <= 2'd0; ldr_st <= 3'd4; end     // un byte al core
			3'd4: if (ldr_gap == 2'd2) ldr_st <= 3'd5; else ldr_gap <= ldr_gap + 2'd1;
			3'd5: if (!prog_we) begin
			          ldr_ptr <= ldr_ptr + 27'd1;
			          ldr_st  <= (ldr_ptr[2:0] == 3'd7 || ldr_ptr + 27'd1 >= rom_len) ? 3'd0 : 3'd3;
			      end
			default: ldr_st <= 3'd0;
		endcase
	end
end

wire [7:0] ldr_byte = ldr_word[{ldr_ptr[2:0], 3'b000} +: 8];

assign ddr_addr = { ROM_DDR, 1'b0, ldr_ptr[26:3] };
assign dl_rom   = hps_rom | ldr_on;
assign dl_wr    = hps_wr  | ldr_wr;
assign dl_addr  = ldr_on ? ldr_ptr[AW-1:0] : hps_addr;
assign dl_dout  = ldr_on ? ldr_byte : hps_dout;

endmodule
