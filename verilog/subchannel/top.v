`include "../components/global.vh"
`include "top__channel.vh"

module top(
    input                      clk,
    input                      global_reset,
    input                      reset,
    //Sample data.
    input                      clk_sample,
    input                      feed_complete,
    input [`INPUT_RANGE]       data,
    //Carrier control.
    input [`DOPPLER_INC_RANGE] doppler,//FIXME range?
    //Code control.
    input [4:0]                prn,
    input                      seek_en,
    input [`CS_RANGE]          seek_target,
    output wire [`CS_RANGE]    code_shift,
    //Outputs.
    output wire [`ACC_RANGE]   accumulator_i,
    output wire [`ACC_RANGE]   accumulator_q,
    output wire [`I2Q2_RANGE]  i2q2,
    output wire                i2q2_valid,
    //Debug signals.
    output wire                ca_bit,
    output wire                ca_clk,
    output wire [9:0]          ca_code_shift);

   //Clock domain crossing.
   (* keep *) wire clk_sample_sync;
   synchronizer input_clk_sync(.clk(clk),
                               .in(clk_sample),
                               .out(clk_sample_sync));
   
   (* keep *) wire reset_sync;
   synchronizer input_reset_sync(.clk(clk),
                                 .in(reset),
                                 .out(reset_sync));
   
   (* keep *) wire [`INPUT_RANGE] data_sync;
   synchronizer #(.WIDTH(`INPUT_WIDTH))
     input_data_sync(.clk(clk),
                     .in(data),
                     .out(data_sync));

   (* keep *) wire feed_complete_sync;
   synchronizer input_feed_complete_sync(.clk(clk),
                                         .in(feed_complete),
                                         .out(feed_complete_sync));

   //Data available strobe.
   (* keep *) wire data_available;
   strobe data_available_strobe(.clk(clk),
                                .reset(reset_sync),
                                .in(clk_sample_sync),
                                .out(data_available));

   //Prompt subchannel.
   channel prompt(.clk(clk),
                  .global_reset(global_reset),
                  .reset(reset_sync),
                  .data_available(data_available),
                  .feed_complete(feed_complete_sync),
                  .data(data_sync),
                  .doppler(doppler),
                  .prn(prn),
                  .seek_en(seek_en),
                  .seek_target(seek_target),
                  .code_shift(code_shift),
                  .accumulator_i(accumulator_i),
                  .accumulator_q(accumulator_q),
                  .i2q2_prompt_valid(i2q2_valid),
                  .i2q2_prompt(i2q2),
                  .ca_bit(ca_bit),
                  .ca_clk(ca_clk),
                  .ca_code_shift(ca_code_shift));
endmodule