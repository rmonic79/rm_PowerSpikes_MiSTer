/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 29-3-2025 */

module jtpspike_header(
    input            clk,
                     header, prog_we,
    
    output reg       pspikes=0,
    output reg       turbofrc=0,
    output reg       karatblz=0,
    output reg       aerofgt=0,
    input      [2:0] prog_addr,
    input      [7:0] prog_data
);

always @(posedge clk) begin
    if( header && prog_addr[2:0]==1 && prog_we )
        pspikes <= prog_data[0];
    if( header && prog_addr[2:0]==1 && prog_we )
        turbofrc <= prog_data[1];
    if( header && prog_addr[2:0]==1 && prog_we )
        karatblz <= prog_data[3];
    if( header && prog_addr[2:0]==1 && prog_we )
        aerofgt <= prog_data[2];
end

endmodule
