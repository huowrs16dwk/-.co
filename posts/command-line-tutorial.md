---
layout: post
title: command line tutorial
date: 2023-08-15
---

# {{ title }}

Terminal jockey zero to hero.  A gentle introduction to one of the most powerful user interfaces in the world.

## preflight

This guide is primarily based on zsh but almost everything will work with bash as well.

Before we get started, some system setup is important

1. Find a great terminal emulator that has the features you want
2. Find a great font that you love to look at

There are several open source fonts available that are pretty great.

- [Programming Fonts List](https://www.programmingfonts.org/)

Some of my favorites:

- Terminus
- FiraMono
- Pragmata Pro (not free)

When it comes to terminal emulators, depending on what OS you are using you'll want to take a look at these:

- Linux: Terminator, alacritty
- OSX: iTerm2
- Windows: ConEmu

Now that you have your terminal emulator and font setup, let's dive right in.

## getting started

listing files

```
ls
```

making a directory

```
mkdir foo
```

creating a new file

```
touch foo/bar
```

changing into a directory

```
cd foo
```

going "up" a directory

```
cd ..
```


## file permissions

Lots of problems on linux systems have to do with file permissions. It's important to understand what file permissions are, how to read them, and how to change them.

listing file permisisons:

```
ls -l
```

example: drwxr-xr-x foo bar

```
d for directory
rwx user permissions (user foo)
r-x group permissions (group bar)
r-x other permissions (anybody not foo and not in bar)

r for read
w for write
x for execute (for directories that means you can cd into it)

- means the permission is not present
```

you can change permisions with chmod:

```
chmod u-w foo # remove write permissions from the user
chmod g+w foo # add write permissions to the group
```

each rwx group can also be represented as a number

```
- = 0
r = 4
w = 2
x = 1
```

And you can add these numbers together, for instance 7 for rwx

You can also change permisions using numbers

```
chmod 755 foo
```


You can change the user and group (owner) of a file with chown:

```
chown baz:qux foo   # change the user to baz
		            # change the group to qux
                    # on the file (or directory) foo
```

## variables

Your shell is effectively a programming environment.  You can set variables and print variables. This can be very useful, let's take a look at some examples:

```
export x=foo # set the varible x to foo
             # export effectively makes it a global variable
             # this means it can be used by other programs

echo $x      # print the value of x

cd $x        # use the x variable and cd into the directory

printenv     # print all the current variables
```



String Variables:

```
fred='/Bin/Path/Fred.txt'

echo ${fred:e}     # txt
echo ${fred:t}     # Fred.txt
echo ${fred:r}     # /Bin/Path/Fred
echo ${fred:h}     # /Bin/Path
echo ${fred:u}     # /BIN/PATH/FRED.TXT
echo ${fred:l}     # /bin/path/fred.txt
echo ${fred:h:h}   # /Bin
echo ${fred:t:r}   # Fred
echo ${fred:t:r:u} # FRED
echo ${fred:5:4}   # Path
echo ${fred::-4}   # /Bin/Path/Fred
```

Numeric Variables:

```
port=80
echo $port             # 80
echo ${port}1          # 801
echo $(( port+1 ))     # 81
```

Variable Expansion:

```
export one=1; export two=2

# single quotes, no expansion
echo '$one\t$two'
$one\t$two

# double quotes expand variables
echo "$one\t$two"
1       2
```

Conventional Variables:

```
$USER            # the current user login name
$HOME            # the current user’s home directory
$PWD             # the current working directory
$PATH            # list of folders searched to resolve commands

$PS1 / $PROMPT   # the left shell prompt
$RPROMPT         # the right shell prompt

$EDITOR          # the default editor to use
```


## ls colors

You can get a directory listing with color and decorators:

```
ls --color -FG
```

If you don't like your colors, you can customize them with the LS_COLORS variable

```
man dircolors
dircolors -b > .zshrc.d/ls-colors.sh
```

Here is an example of what I use:

```
LS_COLORS='rs=0:di=01;33:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32:*.tar=01;31:*.tgz=01;31:*.arc=01;31:*.arj=01;31:*.taz=01;31:*.lha=01;31:*.lz4=01;31:*.lzh=01;31:*.lzma=01;31:*.tlz=01;31:*.txz=01;31:*.tzo=01;31:*.t7z=01;31:*.zip=01;31:*.z=01;31:*.Z=01;31:*.dz=01;31:*.gz=01;31:*.lrz=01;31:*.lz=01;31:*.lzo=01;31:*.xz=01;31:*.bz2=01;31:*.bz=01;31:*.tbz=01;31:*.tbz2=01;31:*.tz=01;31:*.deb=01;31:*.rpm=01;31:*.jar=01;31:*.war=01;31:*.ear=01;31:*.sar=01;31:*.rar=01;31:*.alz=01;31:*.ace=01;31:*.zoo=01;31:*.cpio=01;31:*.7z=01;31:*.rz=01;31:*.cab=01;31:*.jpg=01;35:*.jpeg=01;35:*.gif=01;35:*.bmp=01;35:*.pbm=01;35:*.pgm=01;35:*.ppm=01;35:*.tga=01;35:*.xbm=01;35:*.xpm=01;35:*.tif=01;35:*.tiff=01;35:*.png=01;35:*.svg=01;35:*.svgz=01;35:*.mng=01;35:*.pcx=01;35:*.mov=01;35:*.mpg=01;35:*.mpeg=01;35:*.m2v=01;35:*.mkv=01;35:*.webm=01;35:*.ogm=01;35:*.mp4=01;35:*.m4v=01;35:*.mp4v=01;35:*.vob=01;35:*.qt=01;35:*.nuv=01;35:*.wmv=01;35:*.asf=01;35:*.rm=01;35:*.rmvb=01;35:*.flc=01;35:*.avi=01;35:*.fli=01;35:*.flv=01;35:*.gl=01;35:*.dl=01;35:*.xcf=01;35:*.xwd=01;35:*.yuv=01;35:*.cgm=01;35:*.emf=01;35:*.ogv=01;35:*.ogx=01;35:*.aac=00;36:*.au=00;36:*.flac=00;36:*.m4a=00;36:*.mid=00;36:*.midi=00;36:*.mka=00;36:*.mp3=00;36:*.mpc=00;36:*.ogg=00;36:*.ra=00;36:*.wav=00;36:*.oga=00;36:*.opus=00;36:*.spx=00;36:*.xspf=00;36:';
```


## configuring your shell

both bash and zsh offer incredibly powerful user prompts. The "prompt" is the stuff that is printed before you get to type at the begining of the line.

The most basic prompt is a simple $

The default prompt on your system is probably something like this:

```
[user@host ~]
```

The ~ is a special character, it represents your home folder. If you were to change directories, you'd see the prompt update

You can change the prompt by changing the `PS1` variable

```
export PS1='[\u@\h \w]\n\$ '

\u is the current user
\h is the current host
\w is the current directory (full path)
\n is a line feed
\$ is a $ for regular users and a # for root
```

## getting help

I don't have all the prompt values memorized, but I can look them up in the manual.  

```
man bash
```

This opens up the user manual for bash, you can search with the `/` key. Try searching for "PROMPTING"

```
/prompting
```

You can step to the next search result hit with the `n` key. To quit, press `q`

For a quick one line summary, you can use the whatis command:

```
whatis shuf
shuf (1)             - generate random permutations
```

## editing files

Most systems come with an editor of some kind preinstalled.  nano, vim and emacs are the most common.  I will do a separate tutorial on vim.  Nano works like most text editors you are already familiar with.

```
nano bar
```

You can change your default editor by setting the EDITOR variable

```
export EDITOR=vim
```

- [interactive vim tutorial](https://www.openvim.com/)


## saving things for next time

You probably don't want to have to change your editor or update your prompt variables every time you launch a shell.  Each shell has some special files you can use to run commands automatically when you login to your shell.  For bash, the most common file is ~/.bashrc and for zsh it is ~/.zshrc

Files that start with `.` are "hidden" files.  To see them, you need to pass a flag to the ls command telling it you want to see hidden files.

```
cd ~
ls -a
nano .bashrc
```

Inside this file, you can add whatever commands you want, and they will run each time you start a new shell.

## aliasing

One of the most common things people like to do is create "aliases" for various commands so they don't have to type long ones, they can instead type a short alias.

```
alias ll='ls -l'
alias la='ls -a'
alias f='find'
alias grin='grep -iRn'
```

You can also override the defaults for a command by using the same name:

```
alias nl='nl -ba'
```

To remove an alias, you can use the unalias command:

```
unalias grin
```

To run the raw command one time without unaliasing it, you can prefix it with backslash \

```
\nl < foo.txt
```

## functions

If you have a complicated command that is too big for an alias, but too small to warrent it's own script file, you may want to consider defining a function for it.

```
function lowercase() {
  awk "{ print tolower(\$0) }"
}

function uppercase() {
  awk "{ print toupper(\$0) }"
}
```

You can use the $@ notation to pass through all the parameters at once:

```
function rank() {
  cat $@ | sort | uniq -c | sort -nr
}
```


## running multiple commands

You can run multiple commands by separating them with `;`

```
echo foo; echo bar
```

## pipes and redirection

The pipe `|` operator is very useful.  Using it, you can string multiple sets of commands together.

```
cat file.log | sort | uniq
```


In this example, we view the contents of file.log and then sort it, then select only the unique lines from it.

## common commands

Here are some of the most common commands available on all nix systems.  Take a look at the man pages and poke around.  Think of ways you can string them together with `;` and `|`.

In no particular order:

```
man (1)              - an interface to the system reference manuals
wc (1)               - print newline, word, and byte counts for each file
nl (1)               - number lines of files
date (1)             - print or set the system date and time
cal (1)              - display a calendar
sort (1)             - sort lines of text files
uniq (1)             - report or omit repeated lines
shuf (1)             - generate random permutations
rev (1)              - reverse lines characterwise
tr (1)               - translate or delete characters
grep (1)             - print lines that match patterns
sed (1)              - stream editor for filtering and transforming text
awk (1p)             - pattern scanning and processing language
perl (1perl)         - The Perl 5 language interpreter
cut (1)              - remove sections from each line of files
paste (1)            - merge lines of files
colrm (1)            - remove columns from a file
diff (1)             - compare files line by line
comm (1)             - compare two sorted files line by line
head (1)             - output the first part of files
tail (1)             - output the last part of files
cat (1)              - concatenate files and print on the standard output
tar (1)              - an archiving utility
gzip (1)             - compress or expand files
less (1)             - opposite of more
more (1)             - display the contents of a file in a terminal
base64 (1)           - base64 encode/decode data and print to standard output
file (1)             - determine file type
tee (1)              - read from standard input and write to standard output and files
seq (1)              - print a sequence of numbers
xargs (1)            - build and execute command lines from standard input
fmt (1)              - simple optimal text formatter
numfmt (1)           - Convert numbers from/to human-readable strings
du (1)               - estimate file space usage
find (1)             - search for files in a directory hierarchy
tput (1)             - initialize a terminal or query terminfo database
```


And if you install the "moreutils" package, you'll get these:

- [moreutils](https://joeyh.name/code/moreutils/)

```
chronic: runs a command quietly unless it fails
combine: combine the lines in two files using boolean operations
errno: look up errno names and descriptions
ifdata: get network interface info without parsing ifconfig output
ifne: run a program if the standard input is not empty
isutf8: check if a file or standard input is utf-8
lckdo: execute a program with a lock held
mispipe: pipe two commands, returning the exit status of the first
parallel: run multiple jobs at once
pee: tee standard input to pipes
sponge: soak up standard input and write to a file
ts: timestamp standard input
vidir: edit a directory in your text editor
vipe: insert a text editor into a pipe
zrun: automatically uncompress arguments to command
```


You can find more by looking in your $PATH variable.  Let's take a look at all the places the shell looks for programs:

```
echo $PATH | tr ':' '\n'

/usr/local/sbin
/usr/local/bin
/usr/bin
/usr/bin/site_perl
/usr/bin/vendor_perl
/usr/bin/core_perl
```

When you try to access a program, this is where your shell is looking to find it.  If it's not in one of these folders, it won't be able to find it.  In fact, it looks at these in order, so if you wanted to have a different version of a command be the default, you could make sure that your local path in your home directory is searched first.  Let's do that.

```
export PATH="${HOME}/.bin:${PATH}"
```

Remember, if you want this to stick around, you'll need to add it to your ~/.bashrc or ~/.zshrc

A couple of things going on here that are interesting.

 - First, we are using double quotes: ". This means that variables inside the quotes will be evaluated, so we can reference special variables like $HOME and $PATH and they will expand properly. If we used single quotes ' then the variables would not be expanded.
 - Second, the .bin folder is being put at the beginning of the list.  This means that your shell will look there first before looking in the rest of the system.
 - Third, we are separating the values with a :  This is a special notation for the $PATH variable.  It's a collection of paths separated by :

Cool right? Now we have a local folder in our home directory where we can install more programs and we never have to worry about having extra permissions on the system or cluttering up /usr and /bin directories with personal programs.  These can be programs that we write, or programs we got from the internet.


## streams, indirection and redirection

We already talked about the basics of redirecting output to a file with the > operator, but what if you wanted to read in files, or diff the output from two different commands?

```
# stream the output of cat to jq as input
cat foo.json | jq

# same thing, read the foo.json file and send it to jq stdin
jq < foo.json

# write a file creating or overwriting whatever is there
echo "hello" > file1

# write to a file, appending to the end of it
echo "world" >> file1

# read in foo.json, grep for title, redirect any errors to /dev/null
grep title 2>/dev/null < foo.json

# generate two randomized lists of numbers from 1-10 and compare them
diff <(seq 10 | shuf) <(seq 10 | shuf)

# do the install only if make succeeds
make && make install
```


## basic scripting techniques

Let's write a basic script.  We can print the latest news headlines for example.  First, we will need a way to parse html.  Let's install pup to our ~/.bin folder that we setup earlier.

```
curl -s -L https://github.com/ericchiang/pup/releases/download/v0.4.0/pup_v0.4.0_linux_amd64.zip | zcat > ~/.bin/pup
```

This uses curl to fetch the file and output it to standard out.  We then pipe that into zcat standard in, and zcat decompresses the file to standard out. Then we take that and "arrow" it using the > to the ~/.bin/pup file on the file system.


Now that we have the pup command, in order to use it we have to give ourselves permission to execute it.  Remember chmod?

```
	chmod u+x ~/.bin/pup

Now that we can use the program, let's scrape some news headlines.

	curl -s https://news.ycombinator.com/ | pup 'table table tr:nth-last-of-type(n+2) td.title a json{}'

That grabs headlines and links, but it's not very nice to look at.  Let's see if we can clean up the output.  Since we are working with web data, it's also useful to have jq.  So I've also installed that.

	curl -s https://news.ycombinator.com/ | pup 'table table tr:nth-last-of-type(n+2) td.title a json{}' | jq -r '.[] | {text,href} | select (.text !=null) | "\(.text)\n\(.href)\n\n"'
```


Wow, that's one heck of a command.  Let's see if we can break it up a little bit and figure out what's going on.

```
curl # fetch something from the web
-s	# silently
...	# url to fetch
| 	# pipe stdout to stdin
pup 	# process html
...     # parameters for parsing, selecting out just the section we want from the page
|	# pipe stdout to stdin
jq	# process json
-r	# print the raw value of the string
...	# select the text and href fields where text is not null
```

If you look closely, jq supports it's own pipes.  All of that is one big long string passed to jq to process the json output. You can find more about the pup and jq syntax in their respective documentation.

Let's turn it into a script that we can call any time we want, save this as headlines.sh

```
#!/usr/bin/env bash

html=$(curl -s https://news.ycombinator.com/)
json=$(echo $html |  pup 'table table tr:nth-last-of-type(n+2) td.title a json{}')
echo $json | jq -r '.[] | {text,href} | select (.text !=null) | "\(.text)\n\(.href)\n\n"'
```

Now we can save that file, chmod +x the file, and then we can run it any time and get headlines at our terminal.

The foo=$(bar) notation runs the bar command and saves the output to foo.  You can then use that $foo from anywhere.

That funny little syntax at the top is important.  The "shebang" #! is read by the shell and it's used to identify what program to use to run your script.  In this case it runs the env command and passes it bash creating an isolated environment for the script. The #! must be the first two characters on the first line of the script for it to work.  Without this, you wouldn't be able to make the script executable and run it.  You would need to call the program yourself like this:

```
bash headlines.sh
```

When writing scripts, it's common to have conditionals like "if this directory is empty" or "if this file exists".

```
if [ -s $f ]
then
    	# $f exists and has a size greater than zero
fi
```

The "test" command can also be used

```
test $? -eq 0 && echo "success"
```

The test man page has more examples

```
man test
```

## jobs

Sometimes you have a long running process and you want to run it in the background.  There is a basic job system included in the shell for just that.  One way of forking a job to the background is using the & operator.

```
sleep 60 &
```

The `&` operator forks the process into the background.  You can continue to use your shell and when the command is complete it will notify you it's done at your prompt.

You can see a list of all your jobs using the jobs command

```
jobs
[1]+  Running                 sleep 60 &
```

You can bring a job to the foreground with the 'fg' command.

```
fg 1
```

You can cancel the current foreground job with ctrl+c

```
sleep 60
^C
```

You can suspend the current command with ctrl+z

```
$ sleep 60
^Z
[1]+  Stopped                 sleep 60
```

Once a process is suspended, you can background it with the bg command

```
$ bg 1
[1]+ sleep 60 &
```

One way I like to deal with long running programs is to use the terminal bell.

```
alias bell="echo -n $'\a'"
```

Then I can run jobs and put a bell at the end:

```
curl -s really-large-file ; bell 
```

This works with the job system where you can ctrl+z and then bg the job, when it's complete you'll get a terminal bell.

You can wait for a job to complete with the wait command

```
wait %1
```

If you want to leave a program running and logout, you can "disown it" 

```
nohup sleep 60
```

You can also fork and disown a process using the &! notation

```
sleep 60 &!
```

## command history and shortcuts

Your command history is saved to ~/.bash_history or ~/.zsh_history.  You can view and search it whenever you like.

```
# view command history
history

# search for a command in your history
CTRL+r

# edit the current command in $EDITOR
CTRL+X, CTRL+e
```

The special variable $? shows the return code of the previous command

```
sleep 1
echo $?
0

sleep 60
^C
echo $?
130
```

You can use this variable in your prompt to automatically get more information about why a command has failed.


## switching to zsh

Your default shell is probably bash, but if you want to get the most out of your terminal session you may want to consider zsh.  Zsh is relatively newer and has some quality of life improvements.

```
Bourne-again shell (bash 1989)
+ Korn shell (ksh 1983)
+ TENEX C shell (tcsh 1981)
=
Zee shell (zsh 1990)
```

How you get zsh is going to depend on your operating system and package management.

- [Package Management Cheatsheet](https://distrowatch.com/dwres.php?resource=package-management)

To switch your shell over to using zsh, you'll need to use the chsh command

```
chsh -s /bin/zsh
```

If you don't do anything, the next time you login zsh will prompt you for some information and auto generate some dotfiles for you.  Let's talk a bit more about dotfiles. Your dotfiles are run in a very specific order:

```
set the command search path, environment variables
.zshenv

setup for login shells
.zprofile

set up aliases, functions, etc
.zshrc

run additional commands like `fortune`
.zlogin

run commands when the shell exits like `clear`
.zlogout
```

All of these files are optional

I like to keep my shell configuration organized in folders.  Here is an example of my .zprofile:

```
for f (~/.zshrc.d/**/*.sh) {
   source $f
}

source ~/.zsh-keybindings
source ~/.zsh-prompt
```

This loops over all the files in all the sub-directories of my ~/.zshrc.d and sources them one by one.  This way I can have different files for different things.

Here is an example layout:

```
tree ~/.zshrc.d
├── clients                    # client specific details like ssh tunneling info, variables, etc
│   ├── customer1.sh
│   └── customer2.sh
├── lang                       # language specific setup like setting JAVAHOME or GOPATH correctly
│   ├── go.sh
│   ├── java.sh
│   ├── node.sh
│   ├── python.sh
│   └── rust.sh
└── tools                      # tool and service configuration
    ├── aws.sh
    ├── git.sh
    ├── heroku.sh
    └── virtualbox.sh
```

You can organize this however you like, by client, by command, by programming language, by customer, by environment, all of the files will be sourced when you login it's really more about making it more managable for yourself to edit and update these things instead of having a 10000 line long zshrc file that you have to dig through.

- [zsh faq](https://zsh.sourceforge.io/FAQ/)
- [zsh builtins](https://manpages.org/zshbuiltins)


One of the unique features of zsh is a "right prompt".  You can set the RPROMPT variable just like you would the PS1 or PROMPT variable but the value will display on the right hand side. It's handy for error codes and repository information.  Here's an example right prompt that shows git status:

```
# Color shortcuts
RED=$fg[red]
MAGENTA=$fg[magenta]
YELLOW=$fg[yellow]
GREEN=$fg[green]
WHITE=$fg[white]
BLUE=$fg[blue]
RED_BOLD=$fg_bold[red]
MAGENTA_BOLD=$fg_bold[magenta]
YELLOW_BOLD=$fg_bold[yellow]
GREEN_BOLD=$fg_bold[green]
WHITE_BOLD=$fg_bold[white]
BLUE_BOLD=$fg_bold[blue]
RESET_COLOR=$reset_color

# icons
PROMPT_CHARACTER="»"
ERRORICON="☠"
GITICON="%{$WHITE_BOLD%}\xc2\xb1%{$RESET_COLOR%}"

function testok {
  RETVAL=$?
  if [[ $RETVAL -ne 0 ]]; then
    echo -e "${ERRORICON} %{$RED_BOLD%} $RETVAL %{$RESET_COLOR%} "
  fi
}

precmd () {
  # sets the tab title to current dir
  print -Pn "\e]2;%~\a"

  # command timer
  (( _start >= 0 )) && set -A _elapsed $_elapsed $(( SECONDS-_start ))
  _start=-1
}

preexec () {
  (( $#_elapsed > 10 )) && set -A _elapsed $_elapsed[-10,-1]
  typeset -ig _start=SECONDS
}

function elapsedtime() {
  seconds=${_elapsed[-1]}

  if [[ 0 -ne $seconds ]]; then
    echo -en "%{$BLUE_BOLD%}${seconds}s%{$RESET_COLOR%}"
  fi
}

function gitprompt() {
  branch=`git branch -v 2>/dev/null | grep -o "^\*.*" | cut -d ' ' -f 2`
  if [[ -n "${branch}" ]]; then
    numchanges=`git status -s 2>/dev/null | wc -l | sed 's/\ *//'`
    echo -en "${GITICON} %{$GREEN_BOLD%}${branch}%{$RESET_COLOR%} "
    if [[ 0 -eq ${numchanges} ]]; then
      echo -en "%{$GREEN_BOLD%}${numchanges}%{$RESET_COLOR%} "
    else
      echo -en "%{$YELLOW%}${numchanges}%{$RESET_COLOR%} "
    fi
  fi
}

# Prompt format
PROMPT='$(testok)$(elapsedtime)
%{$YELLOW%}${PWD/#$HOME/~}%{$RESET_COLOR%}
%{$BLUE%}${PROMPT_CHARACTER}%{$RESET_COLOR%} '

RPROMPT=' $(gitprompt)'
```


In my case I have this saved to .zsh-prompt and it's sourced from .zprofile

## keyboard shortcuts

With zsh it's also possible to customize the keyboard shortcuts.  Here's what I use for shift+up and shift+down arrows:

```
# shift up to navigate up a directory
__cd_up()   { builtin pushd ..; echo; __call_precmds; zle reset-prompt }
zle -N __cd_up;   bindkey '^[[1;2A' __cd_up

# shift down to navigate back
__cd_undo() { builtin popd;     echo; __call_precmds; zle reset-prompt }
zle -N __cd_undo; bindkey '^[[1;2B' __cd_undo
```


## super users

You may come across times when you don't have permission or need to "be root" for things but you don't quite know why. This all goes back to the permissions section.  Root can do anything with the hardware of the system, including but not limited to watching all the packets that go in and out of a network interface or reading all your email.

Different ways of switching users:

```
# login as user1
su - user1

# run command as root
sudo command

# login as root
sudo -i
```

sudo is a program that allows users with permissions based on configuration to elevate their priveleges to root temporarily.  It's nice because the user doesn't need to know root's password, they just provide their own password and can be granted access assuming they are configured for it.  The default group for sudo permissions is "wheel".  If you are a member of this group, then you can sudo. You can check the sudo configuration in /etc/sudoers file

If you are root, then you don't need to know another user's password to "become" them.  Any su command will return ok and allow them in as that user. With root permissions any user can not only be root, but they can be any other user as well.

## basic text parsing

For text processing, you'll want to familiarize yourself with regular expressions.  There are some online tools that help a lot:

- [regexr](https://regexr.com/)
- [regexpal](https://www.regexpal.com/)

A basic regular expression is something like this:

```
[a-zA-Z]
```

This matches any upper or lowercase letter in the ascii table.  Numbers can be matched like this:

```
[0-9]
```

So, a simple grep for a CVE in a text file might look like this:

```
grep -R  -E -o 'CVE-[0-9]+-[0-9]+' cvelist
```

The hyphen - inside brackets means "through" so it's matching 0 through 9
The plus + means "at least 1 but maybe more" of something

To search and replace things, you can use the stream editor sed:

```
sed 's/CVE/cve/' < cvelist/2012/5xxx/CVE-2012-5509.json
```

This replaces the "CVE on a line with the lowercase "cve".

- [sed oneliners](https://www.unixguide.net/unix/sedoneliner.shtml)

Useful if you have files that are key/value pairs of lines:

```
alias oddlines="sed 'n; d'"
alias evenlines="sed '1d; n; d'"
```


Awk is incredibly useful.  It provides a way to run three blocks of code, one at the beginning, one for each line, and one at the end of a stream.  Here's an example that averages a column:

```
function avg() {
  awk 'BEGIN{ count=0; sum=0; average=0; } { count++; sum+=$1; } END { printf ("{ \"sum\": %1.16f, \"count\": %d, \"average\": %1.16f }",sum,count,sum/count) }'
}
```

Awk is a whole scripting language just like perl, and it's very command line friendly for small tasks. The begin and end blocks are optional.  Here's an example of standard deviation:

```
# fine for small numbers
function stddev() {
  awk '{sum+=$1; sumsq+=$1*$1} END {print sqrt(sumsq/NR - (sum/NR)**2)}'
}
```

Or just simply printing a single column:

```
alias col1="awk '{ print \$1 }'"
alias col2="awk '{ print \$2 }'"
alias col3="awk '{ print \$3 }'"
alias col4="awk '{ print \$4 }'"
alias col5="awk '{ print \$5 }'"
alias col6="awk '{ print \$6 }'"
alias col7="awk '{ print \$7 }'"
alias col8="awk '{ print \$8 }'"
alias col9="awk '{ print \$9 }'"
```


## looping

The terminal is great for bulk operations.  Any command you can type, you can also run in a loop.

```
for f in $(ls *.7z)
do
	7z x $f
done
```

find can execute commands for all the matches

```
find ~/Downloads/ -name '*.7z' -exec  7z x {} \;
```

xargs supports parallel operations

```
find ~/Downloads/ -name '*.7z' | xargs -P 0 -n 1 7z x
```

## expansion and globbing

Sometimes you want to loop over a set of things that is numeric, you can use expansion for that

```
for month in {01..12}
do
	echo $month
done
```

If you have files that are in nested subfolders, you can use the * or ** wildcards to match.

```
ls *.txt	# all txt files in the current folder

ls */*.txt	# all txt files in all subfolders (1 level deep)

# zsh only
ls **/*.txt	# all txt files in all subfolders (fully recursive)
```


## package managers

It's important to point out that lots of terminal commands are available from language specific package managers.  It's very useful to have python, ruby, node.js and golang all working in a terminal so that you can use commands people have published.

Here's a broad overview:

```
perl / cpan
ruby / gem
python / pip
node.js / npm
```

Here are some of my favorites:

```
sudo pip install httpie
sudo pip install csvkit
sudo pip install pygmentize

npm i -g json
npm i -g underscore-cli
npm i -g http-server
```

## comparing data

I frequently have to compare data.  Diff isn't the only way to do that.

```
diff		compare files line by line
comm		select or reject lines common to two files
diff3		compare three files line by line
vimdiff		compare 2 or more files using vim
colordiff	a tool to colorize diff output
patch		apply a diff file to an original
sdiff		side-by-side merge of file differences
```

Even binary data can be compared:

```
cmp		compare two files byte by byte
md5		calculate a message-digest fingerprint (checksum)
hexdump		ASCII, decimal, hexadecimal, octal dump
strings		print the strings of printable characters in files
xxd		make a hexdump or do the reverse
od		dump files in octal and other formats
```

csv/tsv/pipe

```
sudo pip install csvkit
```

json

```
jq	command line json parser

npm i -g json
npm i -g underscore-cli
```


When all else fails, sql to the rescue

```
sqlite3
.import FILE TABLE
```


## plotting results

Sometimes it's just easier with graphics. It's easy enough to plot data at the terminal:

```
alias plotbox='gnuplot -e "set terminal dumb size $(tput cols),$(tput lines); unset key; unset border; plot \"-\" with boxes"'
alias plotline='gnuplot -e "set terminal dumb size $(tput cols),$(tput lines); unset key; unset border; set grid; plot \"-\" with lines"'
alias plotlinepng='gnuplot -e "set terminal png size 800,600; plot \"-\" title \"data\" with lines"'
alias plotlinejpg='gnuplot -e "set terminal jpeg size 800,600; plot \"-\" title \"data\" with lines"'
alias plotlinesvg='gnuplot -e "set terminal svg size 800,600; plot \"-\" title \"data\" with lines"'
```

Example:

```
seq 100 | shuf | plotline
```

There are also some packages available for more advanced cases:

```
sudo pip install bashplotlib
yay -S ttyplot
```


## working with multimedia

Sometimes you have to process images, audio or video.  Many times it's easier to batch convert or resize things than it is to work on them as individual files in something like Gimp.

For images, you'll want to install imagemagick.  That will give you the convert command:

```
# parallel resize, crop, and convert to png
parallel -i -j $(ls -l *.jpg | wc -l) sh -c "convert '{}' -resize 850 -crop x315 '{}.png'" -- *.jpg
```


For audio, ffmpeg is your friend

```
alias towav="ffmpeg -i pipe:0 -f wav pipe:1"
alias tomp3="ffmpeg -i pipe:0 -f mp3 pipe:1"
alias tomono="ffmpeg -i pipe:0 -f wav -ac 1 pipe:1"

cat foo.wav | tomp3 > foo.mp3
```

And video too:

```
ffmpeg -i input.mp4 -q:v 10 -c:v libvpx -c:a libvorbis output.webm
```

Audio playback is possible too, you can use the media player to play sounds when tasks complete

```
mpv foo.wav
```

What about converting speech to text? You can use whisper

```
pip install openai-whisper

# run speech to text on the audio file
whisper foo.mp3 | tee transcript.txt
```


## system clipboard integration

If you are using Xorg then you can copy and paste with xclip

```
# copy to clipboard
uptime | xclip

# paste from clipboard
xclip -o > uptime.txt
```

If you are using Wayland, there is a wl version:

```
echo "foo" | wl-copy
wl-paste > foo.txt
```

If you are on MacOS you can use the pb commands for the pasteboard

```
echo "foo" | pbcopy
pbpaste > foo.txt
```

And on Windows there is clip

```
echo "foo" | clip
paste > foo.txt
```

Or the powershell version:

```
echo "foo" | Set-Clipboard
Paste-Clipboard > foo.txt
```

In your profile scripts you can check what operating system you are on and assign the correct commands to an alias like c and p.  Then no matter what machine the same c and p commands will work.

## sharing dotfiles across machines

I spent years mucking about with custom functions and then I found chezmoi.  It just works, and I can get over it's quirks.  If you really want to roll your own thing, then more power to you, but for me, chezmoi is good enough.

- [chezmoi home](https://www.chezmoi.io/)


## ssh and networking

Now that you're familiar with the shell and have some things configured, let's go over some basic networking commands that are relavent to the linux system. You may need to install some of these as not all networking tools come as part of all distros.

```
# list all interfaces with colored output
ip -c address

# list only ipv4 addresses:
# a is short form for address
ip -4 a

# list the current route table
ip route

# show the dns information for a particular domain
dig google.com

# trace the route from one computer to another
traceroute google.com

# ping another computer to see if it's available
ping -c 1 192.168.1.1

# list the open ports on the local computer
ss -tunlp

# scan the ports of another computer and see what services are available
nmap 192.168.1.1

# log all network traffic on the host
sudo tcpdump

# log all http and https traffic on the wifi
sudo tcpdump -i wlp4s0 'tcp port 80 or tcp port 443'

# terminal ui to watch the network traffic on the host in real time
sudo nethogs
```


SSH can be used to login to a secure shell on another machine.

```
ssh -i aws-key.pem -L 5432:localhost:5432 ec2-machine
```

You probably don't want to have to type the same arguments to ssh every time like passing in -i or -L all the time.  You can simplify your life with a config file:

```
cat .ssh/config

Host razorcrest
  Hostname 10.10.10.1
  User grogu
  IdentityFile ~/.ssh/grogu

Host mando
  Hostname 10.10.10.10
  User mando
  IdentityFile ~/.ssh/mando
  ProxyJump razorcrest
  LocalForward 80 localhost:8080
```

Now that we've setup an entry for mando we can just type

```
ssh mando
```

And it will automatically pass the identity file, forward the ports, and even jump through a bastion host to get there. The point here is it can be named anything.  ssh will use your config file for the names, so you can call the files and servers anything you like so long as the hostname field is correct.   man ssh_config for more info.  

There are times when I just want to forward a port temporarily, that's when I use this function to setup a tunnel

```
function ssh_tunnel () {
  target=$1
  port=$2

  ssh -N -L ${port}:localhost:${port} ${target}
}
```

The $1 and $2 variables are the parameters to the function:

```
ssh_tunnel foo 80
```


You can copy files to and from remote servers using scp

```
# upload a file
scp localfile remoteserver:/path/to/remote/file

# download a file
scp remoteserver:/path/to/remote/file localfile
```

There are times when you want to transfer a file directly between two computers and not have to download it to one place and upload it to another place because that would take too long or be cumbersome. You can easily do that with netcat.

```
# on computer a listen on port 3333 and write the incoming data to a file foo.txt
nc -l 3333 > readme.md

# on computer b write the contents of a file to the remote computer port 3333
cat readme.md | nc 192.168.1.1 3333
```
	

## system monitoring

The sar command can monitor many things on the system, cpu, memory, disk, network, etc.

```
# everything
sar -A 1

# paging statistics
sar -B 1

# io statistics
sar -b 1

# block devices (hard drives)
sar -d 1

# network statistics for all interfaces
sar -n ALL 1

# network stats for a single interface
sar -n ALL --iface=wlp4s0 1
```
	
For a terminal ui, top is installed on most systems, but there are prettier alternatives

```
# top, available almost everywhere
top

# htop, a prettier top
htop

# btop, a prettier htop
btop
```

For a web gui there are several options.  I like netdata.

- [netdata source](https://github.com/netdata/netdata)

