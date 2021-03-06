// This file is part of the Cornell University Hardware GPS Receiver Project.
// Copyright (C) 2009 - Adam Shapiro (ams348@cornell.edu)
//                      Tom Chatt (tjc42@cornell.edu)
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
`include "global.vh"
`include "channel.vh"
`include "channel__subchannel.vh"
`include "channel__ca_upsampler.vh"
`include "channel__acquisition_controller.vh"
`include "channel__tracking_loops.vh"
`include "top__channel.vh"

`define DEBUG
`include "debug.vh"

module channel(
    input                            clk,
    input                            global_reset,
    input [`MODE_RANGE]              mode,
    input                            mode_reset,
    //Real-time sample interface.
    input                            data_available,
    input [`INPUT_RANGE]             data,
    //Memory bank sample interface.
    input                            mem_data_available,
    input [`INPUT_RANGE]             mem_data,
    input                            frame_start,
    input                            frame_end,
    //Code control.
    input [4:0]                      prn,
    output wire [`CS_RANGE]          code_shift,
    //Channel history.
    output wire                      i2q2_valid,
    output reg [`I2Q2_RANGE]         i2q2_early,
    output reg [`I2Q2_RANGE]         i2q2_prompt,
    output reg [`I2Q2_RANGE]         i2q2_late,
    output reg [`IQ_RANGE]           iq_prompt_km1,
    output reg [`ACC_RANGE_TRACK]    i_prompt_k,
    output reg [`ACC_RANGE_TRACK]    q_prompt_k,
    output reg [`ACC_RANGE_TRACK]    i_prompt_km1,
    output reg [`ACC_RANGE_TRACK]    q_prompt_km1,
    output reg [`W_DF_RANGE]         w_df_k,
    output reg [`W_DF_DOT_RANGE]     w_df_dot_k,
               
    output reg [`DOPPLER_INC_RANGE]  carrier_dphi_k,
    output reg [`CA_PHASE_INC_RANGE] ca_dphi_k,
    output reg [`SAMPLE_COUNT_TRACK_RANGE] tau_prime_k,
    //Tracking results.
    input                            tracking_ready,
    input [`IQ_RANGE]                iq_prompt_k,
    input [`DOPPLER_INC_RANGE]       doppler_inc_kp1,
    input [`W_DF_RANGE]              w_df_kp1,
    input [`W_DF_DOT_RANGE]          w_df_dot_kp1,
    input [`CA_PHASE_INC_RANGE]      ca_dphi_kp1,
    input [`DLL_TAU_RANGE]           tau_prime_kp1,
    //Acquisition results.
    output wire                      acquisition_complete,
    output wire [`I2Q2_RANGE]        acq_peak_i2q2,
    output wire [`DOPPLER_INC_RANGE] acq_peak_doppler,
    output wire [`CS_RANGE]          acq_peak_code_shift,
    //Accumulation debug outputs.
    output wire                      accumulator_updating,
    output wire [`ACC_RANGE]         accumulator_i,
    output wire [`ACC_RANGE]         accumulator_q,
    output wire                      accumulation_complete,
    //Debug outputs.
    input                            track_carrier_en,
    input                            track_code_en,
    output reg [3:0]                 track_count,
    output reg                       track_feed_complete,
    output wire                      ca_bit,
    output wire                      ca_clk,
    output wire [9:0]                ca_code_shift);

   //Flag a mode switch.
   wire mode_switch;
   strobe #(.STROBE_AFTER_RESET(1),
            .FLAG_CHANGE(1))
     mode_switch_strobe(.clk(clk),
                        .reset(global_reset || mode_reset),
                        .in(mode),
                        .out(mode_switch));
   
   wire start_acquisition;
   wire start_tracking;
   assign start_acquisition = mode_switch && mode==`MODE_ACQ;
   assign start_tracking = mode_switch && mode==`MODE_TRACK;

   //Generate a feed completion flag for tracking mode.
   reg [`SAMPLE_COUNT_TRACK_RANGE] sample_count;
   reg track_seek_en;
   always @(posedge clk) begin
      sample_count <= start_tracking ? `SAMPLE_COUNT_TRACK_WIDTH'd0 :
                      !data_available ? sample_count :
                      track_feed_complete ? `SAMPLE_COUNT_TRACK_WIDTH'd0 :
                      sample_count+`SAMPLE_COUNT_TRACK_WIDTH'd1;
      
      track_feed_complete <= start_tracking ? 1'b0 :
                             sample_count==tau_prime_k-`SAMPLE_COUNT_TRACK_WIDTH'd1 ? 1'b1 :
                             1'b0;
   end
   
   //Current Doppler shift phase increment, initialized by
   //acquisition and controlled by tracking loops.
   //reg [`DOPPLER_INC_RANGE] carrier_dphi_k;

   //Acquisition controller.
   `KEEP wire [`DOPPLER_INC_RANGE] acq_dopp_early;
   `KEEP wire [`DOPPLER_INC_RANGE] acq_dopp_prompt;
   `KEEP wire [`DOPPLER_INC_RANGE] acq_dopp_late;
   `KEEP wire                      acq_seek_en;
   `KEEP wire [`CS_RANGE]          acq_seek_target;
   `KEEP wire                      target_reached;
   acquisition_controller acq_controller(.clk(clk),
                                         .global_reset(global_reset),
                                         .start_acquisition(start_acquisition),
                                         .frame_start(frame_start),
                                         .doppler_early(acq_dopp_early),
                                         .doppler_prompt(acq_dopp_prompt),
                                         .doppler_late(acq_dopp_late),
                                         .seek_en(acq_seek_en),
                                         .code_shift(acq_seek_target),
                                         .target_reached(target_reached),
                                         .accumulation_complete(accumulation_complete),
                                         .i2q2_valid(i2q2_valid),
                                         .i2q2_early(i2q2_early),
                                         .i2q2_prompt(i2q2_prompt),
                                         .i2q2_late(i2q2_late),
                                         .acquisition_complete(acquisition_complete),
                                         .peak_i2q2(acq_peak_i2q2),
                                         .peak_doppler(acq_peak_doppler),
                                         .peak_code_shift(acq_peak_code_shift));

   //Upsample the C/A code to the incoming sampling rate.
   //reg [`CA_PHASE_INC_RANGE] ca_dphi_k;
   wire ca_bit_early, ca_bit_prompt, ca_bit_late;
   reg [`CS_RANGE] track_seek_target;
   wire seeking;
   ca_upsampler upsampler(.clk(clk),
                          .reset(global_reset || mode_switch),
                          .mode(mode),
                          .enable(mode==`MODE_ACQ ? mem_data_available : data_available),
                          //Control interface.
                          .prn(prn),
                          .phase_inc_offset(mode==`MODE_ACQ ? `CA_PHASE_INC_WIDTH'd0 : ca_dphi_k),
                          //C/A code output interface.
                          .code_shift(code_shift),
                          .out_early(ca_bit_early),
                          .out_prompt(ca_bit_prompt),
                          .out_late(ca_bit_late),
                          //Seek control.
                          .seek_en(mode==`MODE_ACQ ? acq_seek_en : track_seek_en),
                          .seek_target(mode==`MODE_ACQ ? acq_seek_target : track_seek_target),
                          .seeking(seeking),
                          .target_reached(target_reached),
                          //Debug.
                          .ca_clk(ca_clk),
                          .ca_code_shift(ca_code_shift));
   assign ca_bit = ca_bit_prompt;

   //Reset subchannels immediately after accumulation
   //has finished.
   wire clear_subchannels;
   assign clear_subchannels = accumulation_complete;
   
   //Early subchannel.
   wire early_updating, early_complete;
   `KEEP wire [`ACC_RANGE] acc_i_early, acc_q_early;
   subchannel early(.clk(clk),
                    .global_reset(global_reset),
                    .clear(clear_subchannels),
                    .data_available(mode==`MODE_ACQ ? mem_data_available : data_available),
                    .feed_complete(mode==`MODE_ACQ ? frame_end : track_feed_complete),
                    .data(mode==`MODE_ACQ ? mem_data : data),
                    .doppler(mode==`MODE_ACQ ? acq_dopp_early : carrier_dphi_k),
                    .ca_bit(mode==`MODE_ACQ ? ca_bit_prompt : ca_bit_early),
                    .accumulator_updating(early_updating),
                    .accumulator_i(acc_i_early),
                    .accumulator_q(acc_q_early),
                    .accumulation_complete(early_complete));
   
   //Prompt subchannel.
   `KEEP wire prompt_updating, prompt_complete;
   `KEEP wire [`ACC_RANGE] acc_i_prompt, acc_q_prompt;
   subchannel prompt(.clk(clk),
                     .global_reset(global_reset),
                     .clear(clear_subchannels),
                     .data_available(mode==`MODE_ACQ ? mem_data_available : data_available),
                     .feed_complete(mode==`MODE_ACQ ? frame_end : track_feed_complete),
                     .data(mode==`MODE_ACQ ? mem_data : data),
                     .doppler(mode==`MODE_ACQ ? acq_dopp_prompt : carrier_dphi_k),
                     .ca_bit(ca_bit_prompt),
                     .accumulator_updating(prompt_updating),
                     .accumulator_i(acc_i_prompt),
                     .accumulator_q(acc_q_prompt),
                     .accumulation_complete(prompt_complete));
   assign accumulation_complete = prompt_complete;

   //Debug signals.
   assign accumulator_updating = prompt_updating;
   assign accumulator_i = acc_i_prompt;
   assign accumulator_q = acc_q_prompt;
   
   //Late subchannel.
   wire late_updating, late_complete;
   `KEEP wire [`ACC_RANGE] acc_i_late, acc_q_late;
   subchannel late(.clk(clk),
                   .global_reset(global_reset),
                   .clear(clear_subchannels),
                   .data_available(mode==`MODE_ACQ ? mem_data_available : data_available),
                   .feed_complete(mode==`MODE_ACQ ? frame_end : track_feed_complete),
                   .data(mode==`MODE_ACQ ? mem_data : data),
                   .doppler(mode==`MODE_ACQ ? acq_dopp_late : carrier_dphi_k),
                   .ca_bit(mode==`MODE_ACQ ? ca_bit_prompt : ca_bit_late),
                   .accumulator_updating(late_updating),
                   .accumulator_i(acc_i_late),
                   .accumulator_q(acc_q_late),
                   .accumulation_complete(late_complete));

   //Take the absolute value of I and Q accumulations.
   wire [`ACC_MAG_RANGE] i_early_mag;
   abs #(.WIDTH(`ACC_WIDTH))
     abs_i_early(.in(acc_i_early),
                 .out(i_early_mag));

   wire [`ACC_MAG_RANGE] q_early_mag;
   abs #(.WIDTH(`ACC_WIDTH))
     abs_q_early(.in(acc_q_early),
                 .out(q_early_mag));

   wire [`ACC_MAG_RANGE] i_prompt_mag;
   abs #(.WIDTH(`ACC_WIDTH))
     abs_i_prompt(.in(acc_i_prompt),
                  .out(i_prompt_mag));

   wire [`ACC_MAG_RANGE] q_prompt_mag;
   abs #(.WIDTH(`ACC_WIDTH))
     abs_q_prompt(.in(acc_q_prompt),
                  .out(q_prompt_mag));

   wire [`ACC_MAG_RANGE] i_late_mag;
   abs #(.WIDTH(`ACC_WIDTH))
     abs_i_late(.in(acc_i_late),
                .out(i_late_mag));

   wire [`ACC_MAG_RANGE] q_late_mag;
   abs #(.WIDTH(`ACC_WIDTH))
     abs_q_late(.in(acc_q_late),
                .out(q_late_mag));
   
   reg [`ACC_MAG_RANGE] i_early, q_early;
   reg [`ACC_MAG_RANGE] i_prompt, q_prompt;
   reg [`ACC_MAG_RANGE] i_late, q_late;
   reg acc_ready;
   always @(posedge clk) begin
      i_early <= global_reset ? `ACC_MAG_WIDTH'h0 :
                 accumulation_complete ? i_early_mag :
                 i_early;
      
      q_early <= global_reset ? `ACC_MAG_WIDTH'h0 :
                 accumulation_complete ? q_early_mag :
                 q_early;

      i_prompt <= global_reset ? `ACC_MAG_WIDTH'h0 :
                  accumulation_complete ? i_prompt_mag :
                  i_prompt;
      
      q_prompt <= global_reset ? `ACC_MAG_WIDTH'h0 :
                  accumulation_complete ? q_prompt_mag :
                  q_prompt;

      i_late <= global_reset ? `ACC_MAG_WIDTH'h0 :
                accumulation_complete ? i_late_mag :
                i_late;
      
      q_late <= global_reset ? `ACC_MAG_WIDTH'h0 :
                accumulation_complete ? q_late_mag :
                q_late;

      acc_ready <= global_reset ? 1'b0 :
                   accumulation_complete ? 1'b1 :
                   1'b0;
   end // always @ (posedge clk)

   //Square I and Q for each subchannel. Square
   //starts when an accumulation is finished, or
   //the early or prompt squares complete (3 required).
   wire start_square;
   wire [1:0] i2q2_select_km2;
   assign start_square = acc_ready ||
                         square_complete && i2q2_select!=2'h2;
   
   wire square_complete;
   delay #(.DELAY(5))
     square_delay(.clk(clk),
                  .reset(global_reset),
                  .in(start_square),
                  .out(square_complete));
   
   reg [1:0] i2q2_select;
   always @(posedge clk) begin
      i2q2_select <= global_reset ? 2'h0 :
                     accumulation_complete ? 2'h0 :
                     square_complete ? i2q2_select+2'h1 :
                     i2q2_select;
   end
   
   wire [`I2Q2_RANGE] i2;
   iq_square #(.INPUT_WIDTH(`ACC_MAG_WIDTH),
               .OUTPUT_WIDTH(`I2Q2_WIDTH))
     i2_square(.clock(clk),
               .dataa(i2q2_select==2'h0 ? i_early :
                      i2q2_select==2'h1 ? i_prompt :
                      i_late),
               .result(i2));
   
   wire [`I2Q2_RANGE] q2;
   iq_square #(.INPUT_WIDTH(`ACC_MAG_WIDTH),
               .OUTPUT_WIDTH(`I2Q2_WIDTH))
     q2_square(.clock(clk),
               .dataa(i2q2_select==2'h0 ? q_early :
                      i2q2_select==2'h1 ? q_prompt :
                      q_late),
               .result(q2));

   //Pipe square results for timing.
   `KEEP wire [`I2Q2_RANGE] i2_km1;
   delay #(.WIDTH(`I2Q2_WIDTH))
     i2_delay(.clk(clk),
              .reset(global_reset),
              .in(i2),
              .out(i2_km1));

   `KEEP wire [`I2Q2_RANGE] q2_km1;
   delay #(.WIDTH(`I2Q2_WIDTH))
     q2_delay(.clk(clk),
              .reset(global_reset),
              .in(q2),
              .out(q2_km1));
   
   wire [`I2Q2_RANGE] i2q2_out;
   assign i2q2_out = i2_km1+q2_km1;

   //Pipe sum result for timing.
   wire [`I2Q2_RANGE] i2q2_out_km1;
   delay #(.WIDTH(`I2Q2_WIDTH))
     i2q2_delay(.clk(clk),
                .reset(global_reset),
                .in(i2q2_out),
                .out(i2q2_out_km1));

   //Pipe completion signals to match square/sum pipes.
   wire i2q2_complete;
   delay #(.DELAY(2))
     i2q2_complete_delay(.clk(clk),
                         .reset(global_reset),
                         .in(square_complete),
                         .out(i2q2_complete));
   
   delay #(.WIDTH(2),
           .DELAY(2))
     i2q2_select_delay(.clk(clk),
                       .reset(global_reset),
                       .in(i2q2_select),
                       .out(i2q2_select_km2));

   delay i2q2_valid_delay(.clk(clk),
                          .reset(global_reset),
                          .in(i2q2_complete && i2q2_select_km2==2'h2),
                          .out(i2q2_valid));

   //Store I2Q2 values.
   always @(posedge clk) begin
      i2q2_early <= global_reset ? `I2Q2_WIDTH'h0 :
                    i2q2_complete && i2q2_select_km2==2'h0 ? i2q2_out_km1 :
                    i2q2_early;
      
      i2q2_prompt <= global_reset ? `I2Q2_WIDTH'h0 :
                     i2q2_complete && i2q2_select_km2==2'h1 ? i2q2_out_km1 :
                     i2q2_prompt;
      
      i2q2_late <= global_reset ? `I2Q2_WIDTH'h0 :
                   i2q2_complete && i2q2_select_km2==2'h2 ? i2q2_out_km1 :
                   i2q2_late;
   end // always @ (posedge clk)

   //Store history for tracking loops.
   reg ignore_doppler;
   always @(posedge clk) begin
      //FIXME Don't start accepting tracking loop updates
      //FIXME until after the seek has completed.
      track_seek_en <= start_tracking ? 1'b1 :
                       target_reached && accumulation_complete ? 1'b0 :
                       track_seek_en;
      track_seek_target <= start_tracking ?
                           acq_peak_code_shift :
                           track_seek_target;
      
      track_count <= start_tracking ? 4'd0 :
                     tracking_ready ? track_count+4'd1 :
                     track_count;
      
      i_prompt_k <= accumulation_complete ? acc_i_prompt[`ACC_RANGE_TRACK] : i_prompt_k;
      q_prompt_k <= accumulation_complete ? acc_q_prompt[`ACC_RANGE_TRACK] : q_prompt_k;

      //I/Q history.
      //Note: IQ history value is initialized to 1 to avoid
      //      a divide-by-zero in the tracking loops.
      i_prompt_km1 <= start_tracking ? `ACC_WIDTH_TRACK'd0 :
                      tracking_ready ? i_prompt_k :
                      i_prompt_km1;
      q_prompt_km1 <= start_tracking ? `ACC_WIDTH_TRACK'd0 :
                      tracking_ready ? q_prompt_k :
                      q_prompt_km1;
      iq_prompt_km1 <= start_tracking ? `IQ_WIDTH'd1 :
                       tracking_ready ? iq_prompt_k :
                       iq_prompt_km1;

      //Ignore the first Doppler result reported by the FLL.
      ignore_doppler <= start_tracking ? 1'b1 :
                        tracking_ready ? 1'b0 :
                        ignore_doppler;

      //Carrier generator.
      w_df_k <= start_tracking ? {acq_peak_doppler,{`ANGLE_SHIFT{1'b0}}} :
                !track_carrier_en ? w_df_k :
                tracking_ready && !ignore_doppler ? w_df_kp1 :
                w_df_k;
      w_df_dot_k <= start_tracking ? `W_DF_DOT_WIDTH'd0 :
                    !track_carrier_en ? w_df_dot_k :
                    tracking_ready && !ignore_doppler ? w_df_dot_kp1 :
                    w_df_dot_k;
      carrier_dphi_k <= start_tracking ? acq_peak_doppler :
                        !track_carrier_en ? carrier_dphi_k :
                        tracking_ready && !ignore_doppler ? doppler_inc_kp1 :
                        carrier_dphi_k;

      //Code generator.
      ca_dphi_k <= start_tracking ? `CA_PHASE_INC_WIDTH'd0 :
                   !track_code_en ? ca_dphi_k :
                   tracking_ready ? ca_dphi_kp1 :
                   ca_dphi_k;
      tau_prime_k <= start_tracking ? `SAMPLE_COUNT_TRACK_MAX :
                     !track_code_en ? tau_prime_k :
                     tracking_ready ? `SAMPLE_COUNT_TRACK_MAX+{{(`SAMPLE_COUNT_TRACK_WIDTH-`DLL_TAU_WIDTH){tau_prime_kp1[`DLL_TAU_WIDTH-1]}},tau_prime_kp1} :
                     tau_prime_k;
   end
endmodule