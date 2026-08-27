// EXPECT: line=3 rule=todo message=keep diagnostic parity
const shared_value: u8 = 1;
// TODO: keep diagnostic parity
const another_shared_value: u8 = shared_value + 1;
