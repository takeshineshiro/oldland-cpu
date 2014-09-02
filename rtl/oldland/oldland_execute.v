module oldland_exec(input wire		clk,
		    input wire		rst,
		    input wire [31:0]	ra,
		    input wire [31:0]	rb,
		    input wire [31:0]	imm32,
		    input wire [31:0]	pc_plus_4,
		    input wire [3:0]	rd_sel,
		    input wire		update_rd,
		    input wire [4:0]	alu_opc,
		    input wire		alu_op1_ra,
		    input wire		alu_op1_rb,
		    input wire		alu_op2_rb,
		    input wire		mem_load,
		    input wire		mem_store,
		    input wire [1:0]	mem_width,
		    input wire [2:0]	branch_condition,
		    input wire [1:0]	instr_class,
		    input wire		is_call,
		    input wire		update_carry,
		    input wire		update_flags,
                    input wire [2:0]    cr_sel,
                    input wire          write_cr,
		    output reg		branch_taken,
		    output reg [31:0]	alu_out,
		    output reg		mem_load_out,
		    output reg		mem_store_out,
		    output reg [1:0]	mem_width_out,
		    output reg [31:0]	wr_val,
		    output reg		wr_result,
		    output reg [3:0]	rd_sel_out,
		    output reg		stall_clear,
		    output reg [31:0]	mar,
		    output reg [31:0]	mdr,
		    output reg		mem_wr_en,
                    input wire          is_swi,
		    input wire		is_rfe,
		    output wire [25:0]	vector_base,
		    output reg [31:0]	pc_plus_4_out,
		    input wire		data_abort,
		    input wire		exception_start,
		    input wire		i_valid,
		    output reg		i_valid_out,
		    output reg		irqs_enabled,
		    input wire		exception_disable_irqs,
		    input wire [2:0]	dbg_cr_sel,
		    output wire [31:0]	dbg_cr_val,
		    input wire [31:0]	dbg_cr_wr_val,
		    input wire		dbg_cr_wr_en,
		    input wire		irq_start,
		    input wire [31:0]	irq_fault_address,
		    output wire [2:0]	cpuid_sel,
		    input wire [31:0]	cpuid_val,
		    input wire		cache_instr,
		    output reg		cache_instr_out,
		    output reg [1:0]	cache_op);

wire [31:0]	op1 = alu_op1_ra ? ra : alu_op1_rb ? rb : pc_plus_4;
wire [31:0]	op2 = alu_op2_rb ? rb : imm32;

reg [31:0]	alu_q = 32'b0;
reg		alu_c = 1'b0;
wire		alu_z = (op1 ^ op2) == 32'b0;
reg		alu_n = 1'b0;
reg		alu_o = 1'b0;

reg		branch_condition_met = 1'b0;

/* Status registers, not accessible by the programmer interface. */
reg		c_flag = 1'b0;
reg		z_flag = 1'b0;
reg		o_flag = 1'b0;
reg		n_flag = 1'b0;

reg [25:0]      vector_addr = 26'b0;

wire [4:0]      psr = {irqs_enabled, n_flag, o_flag, c_flag, z_flag};

reg [4:0]       saved_psr = 5'b0;
reg [31:0]      fault_address = 32'b0;
reg [31:0]	data_fault_address = 32'b0;

assign		vector_base = vector_addr;

wire [31:0]	control_regs[0:7];
assign		control_regs[0] = {vector_addr, 6'b0};
assign		control_regs[1] = {27'b0, irqs_enabled, n_flag, o_flag, c_flag, z_flag};
assign		control_regs[2] = {27'b0, saved_psr};
assign		control_regs[3] = fault_address;
assign		control_regs[4] = data_fault_address;
assign		control_regs[5] = 32'b0;
assign		control_regs[6] = 32'b0;
assign		control_regs[7] = 32'b0;

assign		dbg_cr_val = control_regs[dbg_cr_sel];

wire [31:0]	read_cr_val = control_regs[cr_sel];

assign		cpuid_sel = op2[2:0];

initial begin
	branch_taken = 1'b0;
	alu_out = 32'b0;
	mem_load_out = 1'b0;
	mem_store_out = 1'b0;
	wr_result = 1'b0;
	rd_sel_out = 4'b0;
	wr_val = 32'b0;
	mem_width_out = 2'b00;
	stall_clear = 1'b0;
	mar = 32'b0;
	mdr = 32'b0;
	mem_wr_en = 1'b0;
	pc_plus_4_out = 32'b0;
	i_valid_out = 1'b0;
	irqs_enabled = 1'b0;
	cache_instr_out = 1'b0;
	cache_op = 2'b00;
end

always @(*) begin
	alu_c = 1'b0;
	alu_o = 1'b0;
	alu_n = 1'b0;

	case (alu_opc)
	`ALU_OPC_ADD:   {alu_c, alu_q} = op1 + op2;
	`ALU_OPC_ADDC:  {alu_c, alu_q} = op1 + op2 + {31'b0, c_flag};
	`ALU_OPC_SUB:   {alu_c, alu_q} = op1 - op2;
	`ALU_OPC_SUBC:  {alu_c, alu_q} = op1 - op2 - {31'b0, c_flag};
	`ALU_OPC_MUL:	{alu_c, alu_q} = op1 * op2;
	`ALU_OPC_LSL:   {alu_c, alu_q} = {1'b0, op1} << op2[4:0];
	`ALU_OPC_LSR:   alu_q = op1 >> op2[4:0];
	`ALU_OPC_AND:   alu_q = op1 & op2;
	`ALU_OPC_XOR:   alu_q = op1 ^ op2;
        `ALU_OPC_BIC:   alu_q = op1 & ~(1 << op2[4:0]);
	`ALU_OPC_BST:   alu_q = op1 | (1 << op2[4:0]);
	`ALU_OPC_OR:    alu_q = op1 | op2;
	`ALU_OPC_COPYB: alu_q = op2;
	`ALU_OPC_CMP: begin
		{alu_c, alu_q} = op1 - op2;
		alu_o = op1[31] ^ op2[31] && alu_q[31] == op2[31];
		alu_n = alu_q[31];
	end
	`ALU_OPC_MOVHI: alu_q = op1 | {16'b0, op2[15:0]};
	`ALU_OPC_ASR:   alu_q = op1 >>> op2;
	`ALU_OPC_COPYA: alu_q = op1;
	`ALU_OPC_GCR:	alu_q = read_cr_val;
        `ALU_OPC_SWI:   alu_q = {vector_addr, 6'h8};
	`ALU_OPC_RFE:   alu_q = fault_address;
	`ALU_OPC_CPUID:	alu_q = cpuid_val;
	default:        alu_q = 32'b0;
	endcase
end

always @(*) begin
	case (branch_condition)
	3'b111: branch_condition_met = 1'b1;
	3'b001: branch_condition_met = !z_flag;
	3'b010: branch_condition_met = z_flag;
	3'b011: branch_condition_met = !c_flag;
	3'b100: branch_condition_met = c_flag;
	3'b101: branch_condition_met = !z_flag && (n_flag == o_flag);
	3'b110: branch_condition_met = n_flag != o_flag;
	default: branch_condition_met = 1'b0;
	endcase
end

/* CR0: exception vector table base address. */
always @(posedge clk)
	if (rst)
		vector_addr <= 26'b0;
	else if (dbg_cr_wr_en && dbg_cr_sel == 3'h0)
		vector_addr <= dbg_cr_wr_val[31:6];
	else if (write_cr && cr_sel == 3'h0)
                vector_addr <= ra[31:6];

/* CR2: saved PSR. */
always @(posedge clk) begin
	if (rst)
		saved_psr <= 5'b0;
	else if (dbg_cr_wr_en && dbg_cr_sel == 3'h2)
		saved_psr <= dbg_cr_wr_val[4:0];
	else if (is_swi || exception_start || exception_disable_irqs || irq_start)
                saved_psr <= psr;
        else if (write_cr && cr_sel == 3'h2)
                saved_psr <= ra[4:0];
end

/* CR3: fault address register. */
always @(posedge clk)
	if (rst)
		fault_address <= 32'b0;
	else if (dbg_cr_wr_en && dbg_cr_sel == 3'h3)
		fault_address <= dbg_cr_wr_val;
	else if (irq_start)
		fault_address <= irq_fault_address;
	else if (exception_disable_irqs)
                fault_address <= pc_plus_4;
	else if (write_cr && cr_sel == 3'h3)
		fault_address <= ra;

/* CR4: data fault address register. */
always @(posedge clk)
	if (rst)
		data_fault_address <= 32'b0;
	else if (dbg_cr_wr_en && dbg_cr_sel == 3'h4)
		data_fault_address <= dbg_cr_wr_val;
	else if (data_abort)
		data_fault_address <= mar;
	else if (write_cr && cr_sel == 3'h4)
		data_fault_address <= ra;

always @(posedge clk) begin
	if (rst) begin
		alu_out <= 32'b0;
		wr_result <= 1'b0;
		z_flag <= 1'b0;
		c_flag <= 1'b0;
		n_flag <= 1'b0;
		o_flag <= 1'b0;
		irqs_enabled <= 1'b0;
	end else begin
		alu_out <= alu_q;
		wr_result <= update_rd;
		rd_sel_out <= rd_sel;

		if (update_flags) begin
			z_flag <= alu_z;
			n_flag <= alu_n;
			o_flag <= alu_o;
		end

		if (update_carry)
			c_flag <= alu_c;

		if (exception_disable_irqs)
			irqs_enabled <= 1'b0;

		if (is_rfe) begin
			irqs_enabled <= saved_psr[4];
			n_flag <= saved_psr[3];
			o_flag <= saved_psr[2];
			c_flag <= saved_psr[1];
			z_flag <= saved_psr[0];
		end

		/* CR1: PSR. */
		if (write_cr && cr_sel == 3'h1) begin
			irqs_enabled <= ra[4];
			n_flag <= ra[3];
			o_flag <= ra[2];
			c_flag <= ra[1];
			z_flag <= ra[0];
		end else if (dbg_cr_wr_en && dbg_cr_sel == 3'h1) begin
			irqs_enabled <= dbg_cr_wr_val[4];
			n_flag <= dbg_cr_wr_val[3];
			o_flag <= dbg_cr_wr_val[2];
			c_flag <= dbg_cr_wr_val[1];
			z_flag <= dbg_cr_wr_val[0];
		end

		wr_val <= is_call ? pc_plus_4 :
			mem_store ? op2 : alu_q;
	end
end

always @(posedge clk) begin
	if (rst) begin
		branch_taken <= 1'b0;
		stall_clear <= 1'b0;
	end else begin
		branch_taken <= instr_class == `CLASS_BRANCH &&
			(branch_condition_met || is_swi || is_rfe);
		stall_clear <= instr_class == `CLASS_BRANCH;
	end
end

always @(posedge clk) begin
	if (rst) begin
		mem_load_out <= 1'b0;
		mem_store_out <= 1'b0;
		mem_wr_en <= 1'b0;
		i_valid_out <= 1'b0;
	end else begin
		mem_load_out <= mem_load;
		mem_store_out <= mem_store;

		if (mem_store || mem_load) begin
			mem_width_out <= mem_width;
			mar <= alu_q;
			if (mem_store)
				mdr <= rb;
		end

		mem_wr_en <= mem_store;
		pc_plus_4_out <= pc_plus_4;
		i_valid_out <= i_valid;
	end
end

always @(posedge clk) begin
	cache_op <= op2[1:0];
	cache_instr_out <= cache_instr;
end

endmodule

