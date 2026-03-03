const system_program = @import("programs/system");

pub const ID = system_program.ID;
pub const AccountRef = system_program.AccountRef;
pub const Error = system_program.Error;
pub const InstructionTag = system_program.InstructionTag;
pub const encodeTransfer = system_program.encodeTransfer;
pub const encodeCreateAccount = system_program.encodeCreateAccount;
pub const execute = system_program.execute;
