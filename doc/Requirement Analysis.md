我想开发一个Linux系统下的C语言解析器，指定一个文件路径，解析所有.c文件，得到每一个.c文件中所有的函数名，将所有结果保存到fc.json，每个.c文件的存放格式为一个.c文件路径对应一个json对象（里面"fc":[函数名列表]）；没有定义函数的.c文件也要保存到fc.json中，路径：空,还要将其额外保存到null_fc.json中。
1.要求：1.1.对于该路径下的任意一个C语言源文件，凡是符合C语言语法要求的函数定义，都应该能够被识别，尽管代码不规范，只要能编译通过无语法错误，都应该被识别；1.2.要充分利用多进程、多线程等技术，充分利用机器的硬件资源，以提高解析速度；1.3.将所有代码形成一个工程，编写Makefile，通过make可以一键编译下载这个工具，通过make clean一键卸载这个工具；1.4.该工具的名称为parsercfc，终端执行parsercfc -h时可以看到这款工具的提示信息如下：
usage: parsercfc [-h] [-w WORKERS] [-o-fc OUTPUT_FC] [-o-null_fc OUTPUT_NULL_FC] dir

获取指定文件夹路径下的所有.c文件定义的函数名，将每个.c文件中定义的函数声明保存到fc.josn，没有C语言函数定义的.c文件路径保存到null_fc.json

positional arguments:
  dir                   [必选] 要解析的源代码目录路径

options:
  -h, --help            show this help message and exit
  -w WORKERS, --workers WORKERS
                        使用的线程数 (默认为 CPU核心数-1: 11)
  -o-fc OUTPUT_FC       fc.json 的生成路径 (默认: 当前目录下 fc.json)
  -o-null_fc OUTPUT_NULL_FC
                        null_fc.json 的生成路径 (默认: 当前目录下 null_fc.json)

1.5.工具在执行时要增加执行进度、执行完成耗时、总共解析文件数量、总共解析函数数量、没有定义函数的C文件数量等运行信息；

2.总体思路：2.1.编写.l和.y文件，利用Flex&Bison进行词法句法解析；2.2.编写Python脚本，多进程调用Flex&Bison生成的语法分析器，并保存结果，输出运行相关信息。

3.首先生成doc/plan.md，给出开发这个工具的完整计划，包括但不限于详细描述该工具开发的总体流程、各个过程将要用到的技术/工具等。

4.说明文件统一放到doc文件夹下，Makefile放在项目根目录里。
