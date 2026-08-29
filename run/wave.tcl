# wave.tcl - Verdi waveform configuration
# Sourced at startup via: verdi -script wave.tcl

# Open the nWave waveform window (required before any wv* commands)
set nWave [nWaveOpenWindow]

wvCreateGroup "Clock & Reset"
wvAddSignal -group "Clock & Reset" tb_axi_interconnect_5x16.clk
wvAddSignal -group "Clock & Reset" tb_axi_interconnect_5x16.rst

wvCreateGroup "DUT State"
wvAddSignal -group "DUT State" tb_axi_interconnect_5x16.dut.axi_interconnect_inst.state_reg

wvCreateGroup "Master 0 (AW/W/B)"
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_awvalid[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_awready[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_awaddr[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_wvalid[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_wready[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_wdata[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_wstrb[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_bvalid[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_bready[0]}
wvAddSignal -group "Master 0 (AW/W/B)" {tb_axi_interconnect_5x16.s_bresp[0]}

wvCreateGroup "Master 0 (AR/R)"
wvAddSignal -group "Master 0 (AR/R)" {tb_axi_interconnect_5x16.s_arvalid[0]}
wvAddSignal -group "Master 0 (AR/R)" {tb_axi_interconnect_5x16.s_arready[0]}
wvAddSignal -group "Master 0 (AR/R)" {tb_axi_interconnect_5x16.s_araddr[0]}
wvAddSignal -group "Master 0 (AR/R)" {tb_axi_interconnect_5x16.s_rvalid[0]}
wvAddSignal -group "Master 0 (AR/R)" {tb_axi_interconnect_5x16.s_rready[0]}
wvAddSignal -group "Master 0 (AR/R)" {tb_axi_interconnect_5x16.s_rdata[0]}
wvAddSignal -group "Master 0 (AR/R)" {tb_axi_interconnect_5x16.s_rresp[0]}

wvCreateGroup "Slave 0 (AW/W/B)"
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_awvalid[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_awready[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_awaddr[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_wvalid[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_wready[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_wdata[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_bvalid[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_bready[0]}
wvAddSignal -group "Slave 0 (AW/W/B)" {tb_axi_interconnect_5x16.m_bresp[0]}

wvCreateGroup "Slave 0 (AR/R)"
wvAddSignal -group "Slave 0 (AR/R)" {tb_axi_interconnect_5x16.m_arvalid[0]}
wvAddSignal -group "Slave 0 (AR/R)" {tb_axi_interconnect_5x16.m_arready[0]}
wvAddSignal -group "Slave 0 (AR/R)" {tb_axi_interconnect_5x16.m_araddr[0]}
wvAddSignal -group "Slave 0 (AR/R)" {tb_axi_interconnect_5x16.m_rvalid[0]}
wvAddSignal -group "Slave 0 (AR/R)" {tb_axi_interconnect_5x16.m_rready[0]}
wvAddSignal -group "Slave 0 (AR/R)" {tb_axi_interconnect_5x16.m_rdata[0]}
wvAddSignal -group "Slave 0 (AR/R)" {tb_axi_interconnect_5x16.m_rresp[0]}

wvCreateGroup "Arbiter"
wvAddSignal -group "Arbiter" tb_axi_interconnect_5x16.dut.axi_interconnect_inst.grant
wvAddSignal -group "Arbiter" tb_axi_interconnect_5x16.dut.axi_interconnect_inst.grant_valid
wvAddSignal -group "Arbiter" tb_axi_interconnect_5x16.dut.axi_interconnect_inst.grant_encoded

# Zoom to fit
wvZoomAll
