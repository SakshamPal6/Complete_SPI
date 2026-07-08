//=============================================================================
// Full-Duplex SPI Master/Slave Testbench
// Style   : Transaction / Generator / Driver / Monitor / Scoreboard / Env / TB
// DUT     : top (spi_master + spi_slave), 12-bit, configurable CPOL/CPHA
//
// This version runs the SAME class-based testbench across all 4 CPOL/CPHA
// combinations by wrapping it in a parameterized module `tb_spi #(CPOL,CPHA)`
// and instantiating 4 copies from `tb_top`.
//
// NOTE ON FULL-DUPLEX CHECKING:
//   Every transfer moves data BOTH ways at once:
//     master -> slave : m_din  ==> captured in s_dout
//     slave  -> master: s_din  ==> captured in m_dout
//   So the scoreboard checks TWO pairs per transaction, not one.
//=============================================================================

//////////////////// Interface
interface spi_if;
  logic        clk;
  logic        rst;
  logic        newd;
  logic [11:0] m_din;   // driven:  master -> slave data
  logic [11:0] s_din;   // driven:  slave  -> master data
  logic [11:0] m_dout;  // sampled: data master received (should == s_din)
  logic [11:0] s_dout;  // sampled: data slave  received (should == m_din)
  logic        done;    // 1-cycle pulse, transfer complete

  // Hierarchically-tapped internal DUT signals, wired up in the tb module
  // below. These are for monitor/debug visibility only -- never driven here.
  logic        sclk;
  logic        cs;
  logic        mosi;
  logic        miso;

  // ---------------------------------------------------------------
  // Basic protocol checks (helps catch driver/DUT bugs early instead
  // of silently mismatching in the scoreboard). Written as plain
  // procedural checks (instead of SVA) for broad simulator support.
  // ---------------------------------------------------------------
  bit prev_done;

  // done must never stay high for more than one clk cycle
  always @(posedge clk) begin
    if (rst)
      prev_done <= 1'b0;
    else begin
      if (prev_done && done)
        $error("[IF] : DONE stayed high for more than one cycle");
      prev_done <= done;
    end
  end

endinterface


//////////////////// Transaction Class
class transaction;

  bit          newd;          // Flag for new transaction
  rand bit [11:0] m_din;      // Random data: master -> slave
  rand bit [11:0] s_din;      // Random data: slave  -> master
  bit [11:0]   m_dout;        // Captured: master received (expect == s_din)
  bit [11:0]   s_dout;        // Captured: slave  received (expect == m_din)

  function transaction copy();
    copy         = new();
    copy.newd    = this.newd;
    copy.m_din   = this.m_din;
    copy.s_din   = this.s_din;
    copy.m_dout  = this.m_dout;
    copy.s_dout  = this.s_dout;
  endfunction

  function void display(string tag);
    $display("[%0s] : master_din=%0h slave_din=%0h m_dout=%0h s_dout=%0h",
              tag, m_din, s_din, m_dout, s_dout);
  endfunction

endclass


//////////////////// Generator Class
class generator;

  transaction tr;
  mailbox #(transaction) mbx;   // gen -> driver
  event done;                   // signals all transactions issued
  int count = 0;                // number of transactions to generate
  event drvnext;                // (kept for symmetry with reference tb)
  event sconext;                // wait for scoreboard to finish checking

  int cpol, cpha;                // for tagged prints only

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
    tr = new();
  endfunction

  task run();
    repeat (count) begin
      assert (tr.randomize()) else $error("[GEN CPOL=%0d CPHA=%0d] : Randomization Failed", cpol, cpha);
      mbx.put(tr.copy());
      $display("[GEN CPOL = %0d CPHA = %0d] : m_din = %0d  s_din = %0d", cpol, cpha, tr.m_din, tr.s_din);
      @(sconext);
    end
    -> done;
  endtask

endclass


//////////////////// Driver Class
class driver;

  virtual spi_if vif;
  transaction tr;
  mailbox #(transaction) mbx;      // driver <- generator
  mailbox #(transaction) mbxsco;   // driver -> scoreboard (expected values)
  event drvnext;

  int cpol, cpha;                  // for tagged prints only

  function new(mailbox #(transaction) mbxsco, mailbox #(transaction) mbx);
    this.mbx    = mbx;
    this.mbxsco = mbxsco;
  endfunction

  task reset();
    vif.rst   <= 1'b1;
    vif.newd  <= 1'b0;
    vif.m_din <= 1'b0;
    vif.s_din <= 1'b0;
    repeat (10) @(posedge vif.clk);
    vif.rst <= 1'b0;
    repeat (5) @(posedge vif.clk);

    $display("[DRV CPOL = %0d CPHA = %0d] : RESET DONE", cpol, cpha);
    $display("-----------------------------------------");
  endtask

  task run();
    forever begin
      mbx.get(tr);
      vif.newd  <= 1'b1;
      vif.m_din <= tr.m_din;
      vif.s_din <= tr.s_din;
      mbxsco.put(tr.copy());          // send expected data to scoreboard
      @(posedge vif.clk);
      vif.newd <= 1'b0;
      @(posedge vif.done);
      $display("[DRV CPOL = %0d CPHA = %0d] : SENT  m_din = %0d  s_din = %0d", cpol, cpha, tr.m_din, tr.s_din);
      @(posedge vif.clk);
    end
  endtask

endclass


//////////////////// Monitor Class
class monitor;

  transaction tr;
  mailbox #(transaction) mbx;   // monitor -> scoreboard
  virtual spi_if vif;

  int cpol, cpha;                // for tagged prints only

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  task run();
    forever begin
      @(posedge vif.done);
      // Settle delay: m_dout is driven directly off clk, but s_dout is driven
      // off sclk (itself derived from clk inside the master) -- one extra
      // scheduling hop behind done/m_dout. Sampling in the very same delta as
      // @(posedge done) can race that cascade on some simulators. A short
      // delay pushes the read past all same-edge NBA updates, deterministically.
      #1;
      tr = new();
      tr.m_dout = vif.m_dout;
      tr.s_dout = vif.s_dout;
      $display("[MON CPOL = %0d CPHA = %0d] : RCVD  m_dout = %0d  s_dout = %0d", cpol, cpha, tr.m_dout, tr.s_dout);
      mbx.put(tr);
      @(posedge vif.clk);
    end
  endtask

endclass


//////////////////// Scoreboard Class
class scoreboard;

  mailbox #(transaction) mbxds;   // expected data,  from driver
  mailbox #(transaction) mbxms;   // captured data,  from monitor
  event sconext;

  int match_cnt   = 0;
  int mismatch_cnt = 0;

  int cpol, cpha;                  // for tagged prints only

  function new(mailbox #(transaction) mbxds, mailbox #(transaction) mbxms);
    this.mbxds = mbxds;
    this.mbxms = mbxms;
  endfunction

  task run();
    transaction exp, act;
    forever begin
      mbxds.get(exp);
      mbxms.get(act);

      // master -> slave path : m_din should show up on s_dout
      if (exp.m_din === act.s_dout)
        $display("[SCO CPOL = %0d CPHA = %0d] : MASTER -> SLAVE DATA MATCHED", cpol, cpha);
      else begin
        $display("[SCO CPOL = %0d CPHA = %0d] : MASTER -> SLAVE DATA MISMATCHED",
                   cpol, cpha);
        mismatch_cnt++;
      end

      // slave -> master path : s_din should show up on m_dout
      if (exp.s_din === act.m_dout)
        $display("[SCO CPOL = %0d CPHA = %0d] : SLAVE -> MASTER DATA MATCHED", cpol, cpha);
      else begin
        $display("[SCO CPOL = %0d CPHA = %0d] : SLAVE -> MASTER DATA MISMATCHED ",
                   cpol, cpha);
        mismatch_cnt++;
      end

      if (exp.m_din === act.s_dout && exp.s_din === act.m_dout)
        match_cnt++;

      $display("-----------------------------------------");
      -> sconext;
    end
  endtask

  function void report();
    $display("=========================================");
    $display("[SCO CPOL=%0d CPHA=%0d] : TOTAL MATCHED TRANSFERS    : %0d", cpol, cpha, match_cnt);
    $display("[SCO CPOL=%0d CPHA=%0d] : TOTAL MISMATCHED TRANSFERS : %0d", cpol, cpha, mismatch_cnt);
    $display("=========================================");
  endfunction

endclass


//////////////////// Environment Class
class environment;

  generator  gen;
  driver     drv;
  monitor    mon;
  scoreboard sco;

  event nextgs;
  event alldone;      // fires once this env's full run + report is complete

  int cpol, cpha;     // CPOL/CPHA this environment instance is testing

  mailbox #(transaction) mbxgd;   // generator  -> driver
  mailbox #(transaction) mbxds;   // driver     -> scoreboard (expected)
  mailbox #(transaction) mbxms;   // monitor    -> scoreboard (actual)

  virtual spi_if vif;

  function new(virtual spi_if vif, int cpol, int cpha);
    mbxgd = new();
    mbxds = new();
    mbxms = new();

    gen = new(mbxgd);
    drv = new(mbxds, mbxgd);
    mon = new(mbxms);
    sco = new(mbxds, mbxms);

    this.vif  = vif;
    this.cpol = cpol;
    this.cpha = cpha;

    drv.vif = this.vif;
    mon.vif = this.vif;

    // propagate cpol/cpha down for tagged prints
    gen.cpol = cpol;  gen.cpha = cpha;
    drv.cpol = cpol;  drv.cpha = cpha;
    mon.cpol = cpol;  mon.cpha = cpha;
    sco.cpol = cpol;  sco.cpha = cpha;

    gen.sconext = nextgs;
    sco.sconext = nextgs;
  endfunction

  task pre_test();
    $display("=========================================");
    $display("STARTING TEST : CPOL=%0d  CPHA=%0d", cpol, cpha);
    // $display("=========================================");
    drv.reset();
  endtask

  task test();
    fork
      gen.run();
      drv.run();
      mon.run();
      sco.run();
    join_any
  endtask

  task post_test();
    wait (gen.done.triggered);
    sco.report();
    -> alldone;             // let tb_top know this combination finished
  endtask

  task run();
    pre_test();
    test();
    post_test();
  endtask

endclass


//////////////////// Testbench (parameterized per CPOL/CPHA)
module tb_spi #(parameter CPOL = 0, parameter CPHA = 0);

  spi_if vif();

  top #(.DW(12), .CPOL(CPOL), .CPHA(CPHA), .CLK_DIV(4)) dut (
    .clk    (vif.clk),
    .rst    (vif.rst),
    .newd   (vif.newd),
    .m_din  (vif.m_din),
    .s_din  (vif.s_din),
    .m_dout (vif.m_dout),
    .s_dout (vif.s_dout),
    .master_done (vif.done),
    .slave_done  ()
  );

  // Tap internal signals for monitor/debug visibility only
  assign vif.sclk = dut.m1.sclk;
  assign vif.cs   = dut.m1.cs;
  assign vif.mosi = dut.m1.mosi;
  assign vif.miso = dut.s1.miso;

  initial begin
    vif.clk <= 0;
  end

  always #10 vif.clk <= ~vif.clk;

  environment env;

  initial begin
    env = new(vif, CPOL, CPHA);
    env.gen.count = 5;
    // NOTE: env.run() is intentionally NOT called here.
    // tb_top calls start_test() explicitly so the 4 CPOL/CPHA
    // combinations run ONE AT A TIME instead of all at once --
    // that keeps GEN/DRV/MON/SCO console output in clean,
    // un-interleaved blocks, one full run per combination.
  end

  task automatic start_test();
    env.run();
  endtask

endmodule


//////////////////// Top-level TB: run all 4 CPOL/CPHA combinations
//////////////////// ONE AT A TIME for clean, non-interleaved console output
module tb_top;

  tb_spi #(.CPOL(0), .CPHA(0)) t00();
  tb_spi #(.CPOL(0), .CPHA(1)) t01();
  tb_spi #(.CPOL(1), .CPHA(0)) t10();
  tb_spi #(.CPOL(1), .CPHA(1)) t11();

  int total_transactions;
  int total_mismatches;

  initial begin
    t00.start_test();

    t01.start_test();

    t10.start_test();

    t11.start_test();

    // Aggregate results across all 4 combinations by reaching into each
    // tb_spi instance's own `env` handle -- there is no `env` in this
    // module's own scope, only inside t00/t01/t10/t11.
    total_transactions = t00.env.gen.count + t01.env.gen.count
                        + t10.env.gen.count + t11.env.gen.count;
    total_mismatches   = t00.env.sco.mismatch_cnt + t01.env.sco.mismatch_cnt
                        + t10.env.sco.mismatch_cnt + t11.env.sco.mismatch_cnt;

    $display("=========================================");
    $display("ALL 4 CPOL/CPHA COMBINATIONS COMPLETE");
    $display(" TOTAL TRANSACTIONS : %0d", total_transactions);
    $display(" TOTAL ERROR COUNT  : %0d", total_mismatches);
    $display("=========================================");
    $finish();
  end

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_top);
  end

endmodule