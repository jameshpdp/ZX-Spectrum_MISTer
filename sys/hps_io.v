//
// hps_io.v
//
// mist_io-like module for MiSTer
//
// Copyright (c) 2014 Till Harbaum <till@harbaum.org>
// Copyright (c) 2017,2018 Sorgelig
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
///////////////////////////////////////////////////////////////////////

//
// Use buffer to access SD card. It's time-critical part.
//
// for synchronous projects default value for PS2DIV is fine for any frequency of system clock.
// clk_ps2 = CLK_SYS/(PS2DIV*2)
//

// WIDE=1 for 16 bit file I/O
// VDNUM 1-4
module hps_io #(parameter STRLEN=0, PS2DIV=2000, WIDE=0, VDNUM=1, PS2WE=0)
(
	input             clk_sys,
	inout      [44:0] HPS_BUS,

	// parameter STRLEN and the actual length of conf_str have to match
	input [(8*STRLEN)-1:0] conf_str,

	output reg [15:0] joystick_0,
	output reg [15:0] joystick_1,
	output reg [15:0] joystick_analog_0,
	output reg [15:0] joystick_analog_1,

	output      [1:0] buttons,
	output            forced_scandoubler,

	output reg [31:0] status,
	input      [31:0] status_in,
	input             status_set,

	//toggle to force notify of video mode change
	input             new_vmode,

	// SD config
	output reg [VD:0] img_mounted,  // signaling that new image has been mounted
	output reg        img_readonly, // mounted as read only. valid only for active bit in img_mounted
	output reg [63:0] img_size,     // size of image in bytes. valid only for active bit in img_mounted

	// SD block level access
	input      [31:0] sd_lba,
	input      [VD:0] sd_rd,       // only single sd_rd can be active at any given time
	input      [VD:0] sd_wr,       // only single sd_wr can be active at any given time
	output reg        sd_ack,

	// do not use in new projects.
	// CID and CSD are fake except CSD image size field.
	input             sd_conf,
	output reg        sd_ack_conf,

	// SD byte level access. Signals for 2-PORT altsyncram.
	output reg [AW:0] sd_buff_addr,
	output reg [DW:0] sd_buff_dout,
	input      [DW:0] sd_buff_din,
	output reg        sd_buff_wr,

	// ARM -> FPGA download
	output reg        ioctl_download = 0, // signal indicating an active download
	output reg  [7:0] ioctl_index,        // menu index used to upload the file
	output reg        ioctl_wr,
	output reg [24:0] ioctl_addr,         // in WIDE mode address will be incremented by 2
	output reg [DW:0] ioctl_dout,
	output reg [31:0] ioctl_file_ext,
	input             ioctl_wait,

	// RTC MSM6242B layout
	output reg [64:0] RTC,

	// Seconds since 1970-01-01 00:00:00
	output reg [32:0] TIMESTAMP,

	// UART flags
	input      [15:0] uart_mode,

	// ps2 keyboard emulation
	output            ps2_kbd_clk_out,
	output            ps2_kbd_data_out,
	input             ps2_kbd_clk_in,
	input             ps2_kbd_data_in,

	input       [2:0] ps2_kbd_led_status,
	input       [2:0] ps2_kbd_led_use,

	output            ps2_mouse_clk_out,
	output            ps2_mouse_data_out,
	input             ps2_mouse_clk_in,
	input             ps2_mouse_data_in,

	// ps2 alternative interface.

	// [8] - extended, [9] - pressed, [10] - toggles with every press/release
	output reg [10:0] ps2_key = 0,

	// [24] - toggles with every event
	output reg [24:0] ps2_mouse = 0
);

localparam DW = (WIDE) ? 15 : 7;
localparam AW = (WIDE) ?  7 : 8;
localparam VD = VDNUM-1;

wire        io_wait  = ioctl_wait;
wire        io_enable= |HPS_BUS[35:34];
wire        io_strobe= HPS_BUS[33];
wire        io_wide  = (WIDE) ? 1'b1 : 1'b0;
wire [15:0] io_din   = HPS_BUS[31:16];
reg  [15:0] io_dout;

assign HPS_BUS[37]   = io_wait;
assign HPS_BUS[36]   = clk_sys;
assign HPS_BUS[32]   = io_wide;
assign HPS_BUS[15:0] = io_dout;

reg [7:0] cfg;
assign buttons = cfg[1:0];
//cfg[2] - vga_scaler handled in sys_top
//cfg[3] - csync handled in sys_top
assign forced_scandoubler = cfg[4];
//cfg[5] - ypbpr handled in sys_top

// command byte read by the io controller
wire [15:0] sd_cmd =
{
	2'b00,
	(VDNUM>=4) ? sd_wr[3] : 1'b0,
	(VDNUM>=3) ? sd_wr[2] : 1'b0,
	(VDNUM>=2) ? sd_wr[1] : 1'b0,

	(VDNUM>=4) ? sd_rd[3] : 1'b0,
	(VDNUM>=3) ? sd_rd[2] : 1'b0,
	(VDNUM>=2) ? sd_rd[1] : 1'b0,

	4'h5, sd_conf, 1'b1,
	sd_wr[0],
	sd_rd[0]
};

///////////////// calc video parameters //////////////////

wire clk_100 = HPS_BUS[43];
wire clk_vid = HPS_BUS[42];
wire ce_pix  = HPS_BUS[41];
wire de      = HPS_BUS[40];
wire hs      = HPS_BUS[39];
wire vs      = HPS_BUS[38];
wire vs_hdmi = HPS_BUS[44];

reg [31:0] vid_hcnt = 0;
reg [31:0] vid_vcnt = 0;
reg  [7:0] vid_nres = 0;
integer hcnt;

always @(posedge clk_vid) begin
	integer vcnt;
	reg old_vs= 0, old_de = 0, old_vmode = 0;
	reg calch = 0;

	if(ce_pix) begin
		old_vs <= vs;
		old_de <= de;

		if(~vs & ~old_de & de) vcnt <= vcnt + 1;
		if(calch & de) hcnt <= hcnt + 1;
		if(old_de & ~de) calch <= 0;

		if(old_vs & ~vs) begin
			if(hcnt && vcnt) begin
				old_vmode <= new_vmode;
				if(vid_hcnt != hcnt || vid_vcnt != vcnt || old_vmode != new_vmode) vid_nres <= vid_nres + 1'd1;
				vid_hcnt <= hcnt;
				vid_vcnt <= vcnt;
			end
			vcnt <= 0;
			hcnt <= 0;
			calch <= 1;
		end
	end
end

reg [31:0] vid_htime = 0;
reg [31:0] vid_vtime = 0;
reg [31:0] vid_pix = 0;

always @(posedge clk_100) begin
	integer vtime, htime, hcnt;
	reg old_vs, old_hs, old_vs2, old_hs2, old_de, old_de2;
	reg calch = 0;

	old_vs <= vs;
	old_hs <= hs;

	old_vs2 <= old_vs;
	old_hs2 <= old_hs;

	vtime <= vtime + 1'd1;
	htime <= htime + 1'd1;

	if(~old_vs2 & old_vs) begin
		vid_pix <= hcnt;
		vid_vtime <= vtime;
		vtime <= 0;
		hcnt <= 0;
	end

	if(old_vs2 & ~old_vs) calch <= 1;

	if(~old_hs2 & old_hs) begin
		vid_htime <= htime;
		htime <= 0;
	end

	old_de   <= de;
	old_de2  <= old_de;

	if(calch & old_de) hcnt <= hcnt + 1;
	if(old_de2 & ~old_de) calch <= 0;
end

reg [31:0] vid_vtime_hdmi;
always @(posedge clk_100) begin
	integer vtime;
	reg old_vs, old_vs2;

	old_vs <= vs_hdmi;
	old_vs2 <= old_vs;

	vtime <= vtime + 1'd1;

	if(~old_vs2 & old_vs) begin
		vid_vtime_hdmi <= vtime;
		vtime <= 0;
	end
end


/////////////////////////////////////////////////////////

reg [31:0] ps2_key_raw = 0;
wire       pressed  = (ps2_key_raw[15:8] != 8'hf0);
wire       extended = (~pressed ? (ps2_key_raw[23:16] == 8'he0) : (ps2_key_raw[15:8] == 8'he0));

always@(posedge clk_sys) begin
	reg [15:0] cmd;
	reg  [9:0] byte_cnt;   // counts bytes
	reg  [2:0] b_wr;
	reg  [2:0] stick_idx;
	reg        ps2skip = 0;
	reg  [3:0] stflg = 0;
	reg [31:0] status_req;

	if(status_set) begin
		stflg <= stflg + 1'd1;
		status_req <= status_in;
	end

	sd_buff_wr <= b_wr[0];
	if(b_wr[2] && (~&sd_buff_addr)) sd_buff_addr <= sd_buff_addr + 1'b1;
	b_wr <= (b_wr<<1);

	{kbd_rd,kbd_we,mouse_rd,mouse_we} <= 0;

	if(~io_enable) begin
		if(cmd == 4 && !ps2skip) ps2_mouse[24] <= ~ps2_mouse[24];
		if(cmd == 5 && !ps2skip) begin
			ps2_key <= {~ps2_key[10], pressed, extended, ps2_key_raw[7:0]};
			if(ps2_key_raw == 'hE012E07C) ps2_key[9:0] <= 'h37C; // prnscr pressed
			if(ps2_key_raw == 'h7CE0F012) ps2_key[9:0] <= 'h17C; // prnscr released
			if(ps2_key_raw == 'hF014F077) ps2_key[9:0] <= 'h377; // pause  pressed
		end
		if(cmd == 'h22) RTC[64] <= ~RTC[64];
		if(cmd == 'h24) TIMESTAMP[32] <= ~TIMESTAMP[32];
		cmd <= 0;
		byte_cnt <= 0;
		sd_ack <= 0;
		sd_ack_conf <= 0;
		io_dout <= 0;
		ps2skip <= 0;
	end else begin
		if(io_strobe) begin

			io_dout <= 0;
			if(~&byte_cnt) byte_cnt <= byte_cnt + 1'd1;

			if(byte_cnt == 0) begin
				cmd <= io_din;

				case(io_din)
					'h19: sd_ack_conf <= 1;
					'h17,
					'h18: sd_ack <= 1;
					'h29: io_dout <= {4'hA, stflg};
				endcase

				sd_buff_addr <= 0;
				img_mounted <= 0;
				if(io_din == 5) ps2_key_raw <= 0;
			end else begin

				case(cmd)
					// buttons and switches
					'h01: cfg        <= io_din[7:0];
					'h02: joystick_0 <= io_din;
					'h03: joystick_1 <= io_din;

					// store incoming ps2 mouse bytes
					'h04: begin
							mouse_data <= io_din[7:0];
							mouse_we   <= 1;
							if(&io_din[15:8]) ps2skip <= 1;
							if(~&io_din[15:8] & ~ps2skip) begin
								case(byte_cnt)
									1: ps2_mouse[7:0]   <= io_din[7:0];
									2: ps2_mouse[15:8]  <= io_din[7:0];
									3: ps2_mouse[23:16] <= io_din[7:0];
								endcase
							end
						end

					// store incoming ps2 keyboard bytes
					'h05: begin
							if(&io_din[15:8]) ps2skip <= 1;
							if(~&io_din[15:8] & ~ps2skip) ps2_key_raw[31:0] <= {ps2_key_raw[23:0], io_din[7:0]};
							kbd_data <= io_din[7:0];
							kbd_we <= 1;
						end

					// reading config string, returning a byte from string
					'h14: if(byte_cnt < STRLEN + 1) io_dout[7:0] <= conf_str[(STRLEN - byte_cnt)<<3 +:8];

					// reading sd card status
					'h16: case(byte_cnt)
								1: io_dout <= sd_cmd;
								2: io_dout <= sd_lba[15:0];
								3: io_dout <= sd_lba[31:16];
							endcase

					// send SD config IO -> FPGA
					// flag that download begins
					// sd card knows data is config if sd_dout_strobe is asserted
					// with sd_ack still being inactive (low)
					'h19,
					// send sector IO -> FPGA
					// flag that download begins
					'h17: begin
							sd_buff_dout <= io_din[DW:0];
							b_wr <= 1;
						end

					// reading sd card write data
					'h18: begin
							if(~&sd_buff_addr) sd_buff_addr <= sd_buff_addr + 1'b1;
							io_dout <= sd_buff_din;
						end

					// joystick analog
					'h1a: case(byte_cnt)
								1: stick_idx <= io_din[2:0]; // first byte is joystick index
								2: if(stick_idx == 0) joystick_analog_0 <= io_din;
									else if(stick_idx == 1) joystick_analog_1 <= io_din;
							endcase

					// notify image selection
					'h1c: begin
							img_mounted  <= io_din[VD:0] ? io_din[VD:0] : 1'b1;
							img_readonly <= io_din[7];
						end

					// send image info
					'h1d: if(byte_cnt<5) img_size[{byte_cnt-1'b1, 4'b0000} +:16] <= io_din;

					// status, 32bit version
					'h1e: if(byte_cnt==1) status[15:0] <= io_din;
								else if(byte_cnt==2) status[31:16] <= io_din;

					// reading keyboard LED status
					'h1f: io_dout <= {|PS2WE, 2'b01, ps2_kbd_led_status[2], ps2_kbd_led_use[2], ps2_kbd_led_status[1], ps2_kbd_led_use[1], ps2_kbd_led_status[0], ps2_kbd_led_use[0]};

					// reading ps2 keyboard/mouse control
					'h21: if(byte_cnt == 1) begin
								io_dout <= kbd_data_host;
								kbd_rd <= 1;
							end
							else
							if(byte_cnt == 2) begin
								io_dout <= mouse_data_host;
								mouse_rd <= 1;
							end
					//RTC
					'h22: RTC[(byte_cnt-6'd1)<<4 +:16] <= io_din;

					//Video res.
					'h23: case(byte_cnt)
								1: io_dout <= vid_nres;
								2: io_dout <= vid_hcnt[15:0];
								3: io_dout <= vid_hcnt[31:16];
								4: io_dout <= vid_vcnt[15:0];
								5: io_dout <= vid_vcnt[31:16];
								6: io_dout <= vid_htime[15:0];
								7: io_dout <= vid_htime[31:16];
								8: io_dout <= vid_vtime[15:0];
								9: io_dout <= vid_vtime[31:16];
							  10: io_dout <= vid_pix[15:0];
							  11: io_dout <= vid_pix[31:16];
							  12: io_dout <= vid_vtime_hdmi[15:0];
							  13: io_dout <= vid_vtime_hdmi[31:16];
							endcase

					//RTC
					'h24: TIMESTAMP[(byte_cnt-6'd1)<<4 +:16] <= io_din;

					//UART flags
					'h28: io_dout <= uart_mode;

					//status set
					'h29: case(byte_cnt)
								1: io_dout <= status_req[15:0];
								2: io_dout <= status_req[31:16];
							endcase
				endcase
			end
		end
	end
end


///////////////////////////////   PS2   ///////////////////////////////
reg clk_ps2;
always @(negedge clk_sys) begin
	integer cnt;
	cnt <= cnt + 1'd1;
	if(cnt == PS2DIV) begin
		clk_ps2 <= ~clk_ps2;
		cnt <= 0;
	end
end

reg  [7:0] kbd_data;
reg        kbd_we;
wire [8:0] kbd_data_host;
reg        kbd_rd;

ps2_device keyboard
(
	.clk_sys(clk_sys),

	.wdata(kbd_data),
	.we(kbd_we),

	.ps2_clk(clk_ps2),
	.ps2_clk_out(ps2_kbd_clk_out),
	.ps2_dat_out(ps2_kbd_data_out),

	.ps2_clk_in(ps2_kbd_clk_in  || !PS2WE),
	.ps2_dat_in(ps2_kbd_data_in || !PS2WE),

	.rdata(kbd_data_host),
	.rd(kbd_rd)
);

reg  [7:0] mouse_data;
reg        mouse_we;
wire [8:0] mouse_data_host;
reg        mouse_rd;

ps2_device mouse
(
	.clk_sys(clk_sys),

	.wdata(mouse_data),
	.we(mouse_we),

	.ps2_clk(clk_ps2),
	.ps2_clk_out(ps2_mouse_clk_out),
	.ps2_dat_out(ps2_mouse_data_out),

	.ps2_clk_in(ps2_mouse_clk_in  || !PS2WE),
	.ps2_dat_in(ps2_mouse_data_in || !PS2WE),

	.rdata(mouse_data_host),
	.rd(mouse_rd)
);


///////////////////////////////   DOWNLOADING   ///////////////////////////////

localparam UIO_FILE_TX      = 8'h53;
localparam UIO_FILE_TX_DAT  = 8'h54;
localparam UIO_FILE_INDEX   = 8'h55;
localparam UIO_FILE_INFO    = 8'h56;

always@(posedge clk_sys) begin
	reg [15:0] cmd;
	reg  [2:0] cnt;
	reg        has_cmd;
	reg [24:0] addr;
	reg        wr;

	ioctl_wr <= wr;
	wr <= 0;

	if(~io_enable) has_cmd <= 0;
	else begin
		if(io_strobe) begin

			if(!has_cmd) begin
				cmd <= io_din;
				has_cmd <= 1;
				cnt <= 0;
			end else begin

				case(cmd)
					UIO_FILE_INFO:
						if(~cnt[1]) begin
							case(cnt)
								0: ioctl_file_ext[31:16] <= io_din;
								1: ioctl_file_ext[15:00] <= io_din;
							endcase
							cnt <= cnt + 1'd1;
						end

					UIO_FILE_INDEX:
						begin
							ioctl_index <= io_din[7:0];
						end

					UIO_FILE_TX:
						begin
							if(io_din[7:0]) begin
								addr <= 0;
								ioctl_download <= 1;
							end else begin
								ioctl_addr <= addr;
								ioctl_download <= 0;
							end
						end

					UIO_FILE_TX_DAT:
						begin
							ioctl_addr <= addr;
							ioctl_dout <= io_din[DW:0];
							wr   <= 1;
							addr <= addr + (WIDE ? 2'd2 : 2'd1);
						end
				endcase
			end
		end
	end
end

endmodule

//////////////////////////////////////////////////////////////////////////////////


module ps2_device #(parameter PS2_FIFO_BITS=5)
(
	input        clk_sys,

	input  [7:0] wdata,
	input        we,

	input        ps2_clk,
	output reg   ps2_clk_out,
	output reg   ps2_dat_out,
	output reg   tx_empty,

	input        ps2_clk_in,
	input        ps2_dat_in,

	output [8:0] rdata,
	input        rd
);


(* ramstyle = "logic" *) reg [7:0] fifo[1<<PS2_FIFO_BITS];

reg [PS2_FIFO_BITS-1:0] wptr;
reg [PS2_FIFO_BITS-1:0] rptr;

reg [2:0] rx_state = 0;
reg [3:0] tx_state = 0;

reg       has_data;
reg [7:0] data;
assign    rdata = {has_data, data};

always@(posedge clk_sys) begin
	reg [7:0] tx_byte;
	reg parity;
	reg r_inc;
	reg old_clk;
	reg [1:0] timeout;

	reg [3:0] rx_cnt;

	reg c1,c2,d1;

	tx_empty <= ((wptr == rptr) && (tx_state == 0));

	if(we) begin
		fifo[wptr] <= wdata;
		wptr <= wptr + 1'd1;
	end

	if(rd) has_data <= 0;

	c1 <= ps2_clk_in;
	c2 <= c1;
	d1 <= ps2_dat_in;
	if(!rx_state && !tx_state && ~c2 && c1 && ~d1) begin
		rx_state <= rx_state + 1'b1;
		ps2_dat_out <= 1;
	end

	old_clk <= ps2_clk;
	if(~old_clk & ps2_clk) begin

		if(rx_state) begin
			case(rx_state)
				1: begin
						rx_state <= rx_state + 1'b1;
						rx_cnt <= 0;
					end

				2: begin
						if(rx_cnt <= 7) data <= {d1, data[7:1]};
						else rx_state <= rx_state + 1'b1;
						rx_cnt <= rx_cnt + 1'b1;
					end

				3: if(d1) begin
						rx_state <= rx_state + 1'b1;
						ps2_dat_out <= 0;
					end

				4: begin
						ps2_dat_out <= 1;
						has_data <= 1;
						rx_state <= 0;
					end
			endcase
		end else begin

			// transmitter is idle?
			if(tx_state == 0) begin
				// data in fifo present?
				if(c2 && c1 && d1 && wptr != rptr) begin

					timeout <= timeout - 1'd1;
					if(!timeout) begin
						tx_byte <= fifo[rptr];
						rptr <= rptr + 1'd1;

						// reset parity
						parity <= 1;

						// start transmitter
						tx_state <= 1;

						// put start bit on data line
						ps2_dat_out <= 0;			// start bit is 0
					end
				end
			end else begin

				// transmission of 8 data bits
				if((tx_state >= 1)&&(tx_state < 9)) begin
					ps2_dat_out <= tx_byte[0];	          // data bits
					tx_byte[6:0] <= tx_byte[7:1]; // shift down
					if(tx_byte[0])
						parity <= !parity;
				end

				// transmission of parity
				if(tx_state == 9) ps2_dat_out <= parity;

				// transmission of stop bit
				if(tx_state == 10) ps2_dat_out <= 1;    // stop bit is 1

				// advance state machine
				if(tx_state < 11) tx_state <= tx_state + 1'd1;
					else tx_state <= 0;
			end
		end
	end

	if(~old_clk & ps2_clk) ps2_clk_out <= 1;
	if(old_clk & ~ps2_clk) ps2_clk_out <= ((tx_state == 0) && (rx_state<2));

end

endmodule
