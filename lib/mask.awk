# Mask stdin to stdout. Password from ENVIRON["TDX_MASK_PW"] (never on the command line).
BEGIN { mask_init(ENVIRON["TDX_MASK_PW"]) }
{ print mask_line($0) }
