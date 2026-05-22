use colored::Colorize;

pub struct Logger {
    pub verbose: bool,
    pub quiet: bool,
}

impl Logger {
    pub fn new(verbose: bool) -> Self {
        Self { verbose, quiet: false }
    }

    pub fn quiet() -> Self {
        Self { verbose: false, quiet: true }
    }

    pub fn info(&self, msg: &str) {
        if !self.quiet {
            println!("{}", msg.blue());
        }
    }

    pub fn success(&self, msg: &str) {
        if !self.quiet {
            println!("{} {}", "✅".green(), msg.green());
        }
    }

    pub fn warn(&self, msg: &str) {
        if !self.quiet {
            println!("{}  {}", "⚠️".yellow(), msg.yellow());
        }
    }

    pub fn error(&self, msg: &str) {
        eprintln!("{} {}", "❌".red(), msg.red());
    }

    pub fn detail(&self, msg: &str) {
        if self.verbose && !self.quiet {
            println!("   {}", msg.cyan());
        }
    }

    pub fn line(&self) {
        if !self.quiet {
            println!();
        }
    }

    pub fn header(&self, msg: &str) {
        if !self.quiet {
            println!("{}", msg.blue());
            println!("{}", "═════════════════════════════════════════════════════════════".blue());
            println!();
        }
    }
}
