'---------------------------------------------------------------------------------------
' Module    : modEncoding
' Author    : Adam Waller
' Date      : 12/4/2020
' Purpose   : Functions for reading and converting file encodings (Unicode, UTF-8)
'---------------------------------------------------------------------------------------
Option Compare Database
Option Private Module
Option Explicit



' Cache the Ucs2 requirement for this database
Private m_blnUcs2 As Boolean
Private m_strDbPath As String


'---------------------------------------------------------------------------------------
' Procedure : RequiresUcs2
' Author    : Adam Waller
' Date      : 5/5/2020
' Purpose   : Returns true if the current database requires objects to be converted
'           : to Ucs2 format before importing. (Caching value for subsequent calls.)
'           : While this involves creating a new querydef object each time, the idea
'           : is that this would be faster than exporting a form if no queries exist
'           : in the current database.
'---------------------------------------------------------------------------------------
'
Public Function RequiresUcs2(Optional blnUseCache As Boolean = True) As Boolean

    Dim strTempFile As String
    Dim frm As Access.Form
    Dim strName As String
    Dim dbs As DAO.Database
    
    ' See if we already have a cached value
    If (m_strDbPath <> CurrentProject.FullName) Or Not blnUseCache Then
    
        ' Get temp file name
        strTempFile = GetTempFile
        
        ' Can't create querydef objects in ADP databases, so we have to use something else.
        If CurrentProject.ProjectType = acADP Then
            ' Create and export a blank form object.
            ' Turn of screen updates to improve performance and avoid flash.
            DoCmd.Echo False
            'strName = "frmTEMP_UCS2_" & Round(Timer)
            Set frm = Application.CreateForm
            strName = frm.Name
            DoCmd.Close acForm, strName, acSaveYes
            Perf.OperationStart "App.SaveAsText()"
            Application.SaveAsText acForm, strName, strTempFile
            Perf.OperationEnd
            DoCmd.DeleteObject acForm, strName
            DoCmd.Echo True
        Else
            ' Standard MDB database.
            ' Create and export a querydef object. Fast and light.
            strName = "qryTEMP_UCS2_" & Round(Timer)
            Set dbs = CurrentDb
            dbs.CreateQueryDef strName, "SELECT 1"
            Perf.OperationStart "App.SaveAsText()"
            Application.SaveAsText acQuery, strName, strTempFile
            Perf.OperationEnd
            dbs.QueryDefs.Delete strName
        End If
        
        ' Test and delete temp file
        m_strDbPath = CurrentProject.FullName
        m_blnUcs2 = HasUcs2Bom(strTempFile)
        DeleteFile strTempFile, True

    End If

    ' Return cached value
    RequiresUcs2 = m_blnUcs2
    
End Function


'---------------------------------------------------------------------------------------
' Procedure : ConvertUcs2Utf8
' Author    : Adam Waller
' Date      : 1/23/2019
' Purpose   : Convert a UCS2-little-endian encoded file to UTF-8.
'           : Typically the source file will be a temp file.
'---------------------------------------------------------------------------------------
'
Public Sub ConvertUcs2Utf8(strSourceFile As String, strDestinationFile As String, _
    Optional blnDeleteSourceFileAfterConversion As Boolean = True)

    Dim cData As clsConcat
    Dim blnIsAdp As Boolean
    Dim intTristate As Tristate
    
    ' Remove any existing file.
    If FSO.FileExists(strDestinationFile) Then DeleteFile strDestinationFile, True
    
    ' ADP Projects do not use the UCS BOM, but may contain mixed UTF-16 content
    ' representing unicode characters.
    blnIsAdp = (CurrentProject.ProjectType = acADP)
    
    ' Check the first couple characters in the file for a UCS BOM.
    If HasUcs2Bom(strSourceFile) Or blnIsAdp Then
    
        ' Determine format
        If blnIsAdp Then
            ' Possible mixed UTF-16 content
            intTristate = TristateMixed
        Else
            ' Fully encoded as UTF-16
            intTristate = TristateTrue
        End If
        
        ' Log performance
        Perf.OperationStart "Unicode Conversion"
        
        ' Read file contents and delete (temp) source file
        Set cData = New clsConcat
        With FSO.OpenTextFile(strSourceFile, ForReading, False, intTristate)
            ' Read chunks of text, rather than the whole thing at once for massive
            ' performance gains when reading large files.
            ' See https://docs.microsoft.com/is-is/sql/ado/reference/ado-api/readtext-method
            Do While Not .AtEndOfStream
                cData.Add .Read(131072) ' 128K
            Loop
            .Close
        End With
        
        ' Write as UTF-8 in the destination file.
        ' (Path will be verified before writing)
        WriteFile cData.GetStr, strDestinationFile
        Perf.OperationEnd
        
        ' Remove the source (temp) file if specified
        If blnDeleteSourceFileAfterConversion Then DeleteFile strSourceFile, True
    Else
        ' No conversion needed, move/copy to destination.
        VerifyPath strDestinationFile
        If blnDeleteSourceFileAfterConversion Then
            FSO.MoveFile strSourceFile, strDestinationFile
        Else
            FSO.CopyFile strSourceFile, strDestinationFile
        End If
    End If
    
End Sub


'---------------------------------------------------------------------------------------
' Procedure : ConvertUtf8Ucs2
' Author    : Adam Waller
' Date      : 1/24/2019
' Purpose   : Convert the file to old UCS-2 unicode format.
'           : Typically the destination file will be a temp file.
'---------------------------------------------------------------------------------------
'
Public Sub ConvertUtf8Ucs2(strSourceFile As String, strDestinationFile As String, _
    Optional blnDeleteSourceFileAfterConversion As Boolean = True)

    Dim strText As String
    Dim utf8Bytes() As Byte

    ' Make sure the path exists before we write a file.
    VerifyPath strDestinationFile
    If FSO.FileExists(strDestinationFile) Then DeleteFile strDestinationFile, True
    
    If HasUcs2Bom(strSourceFile) Then
        ' No conversion needed, move/copy to destination.
        If blnDeleteSourceFileAfterConversion Then
            FSO.MoveFile strSourceFile, strDestinationFile
        Else
            FSO.CopyFile strSourceFile, strDestinationFile
        End If
    Else
        ' Monitor performance
        Perf.OperationStart "Unicode Conversion"
        
        ' Read file contents and convert byte array to string
        utf8Bytes = GetFileBytes(strSourceFile)
        strText = Utf8BytesToString(utf8Bytes)
        
        ' Write as UCS-2 LE (BOM)
        With FSO.CreateTextFile(strDestinationFile, True, True)
            .Write strText
            .Close
        End With
        Perf.OperationEnd
        
        ' Remove original file if specified.
        If blnDeleteSourceFileAfterConversion Then DeleteFile strSourceFile, True
    End If
    
End Sub


'---------------------------------------------------------------------------------------
' Procedure : ConvertAnsiiUtf8
' Author    : Adam Waller
' Date      : 2/3/2021
' Purpose   : Convert an ANSI encoded file to UTF-8. This allows extended characters
'           : to properly display in diffs and other programs. See issue #154
'---------------------------------------------------------------------------------------
'
Public Sub ConvertAnsiUtf8(strSourceFile As String, strDestinationFile As String, _
    Optional blnDeleteSourceFileAfterConversion As Boolean = True)
    
    ReEncodeFile strSourceFile, "_autodetect_all", strDestinationFile, "UTF-8", adSaveCreateOverWrite

    If blnDeleteSourceFileAfterConversion Then DeleteFile strSourceFile
    
End Sub


'---------------------------------------------------------------------------------------
' Procedure : ConvertUtf8Ansii
' Author    : Adam Waller
' Date      : 2/3/2021
' Purpose   : Convert a UTF-8 file back to ANSI.
'---------------------------------------------------------------------------------------
'
Public Sub ConvertUtf8Ansi(strSourceFile As String, strDestinationFile As String, _
    Optional blnDeleteSourceFileAfterConversion As Boolean = True)
    
    ' Perform file conversion
    Perf.OperationStart "ANSI Conversion"
    ReEncodeFile strSourceFile, "UTF-8", strDestinationFile, "_autodetect_all", adSaveCreateOverWrite
    Perf.OperationEnd
    
    ' Remove original file if specified.
    If blnDeleteSourceFileAfterConversion Then DeleteFile strSourceFile
    
End Sub


'---------------------------------------------------------------------------------------
' Procedure : HasUtf8Bom
' Author    : Adam Waller
' Date      : 7/30/2020
' Purpose   : Returns true if the file begins with a UTF-8 BOM
'---------------------------------------------------------------------------------------
'
Public Function HasUtf8Bom(strFilePath As String) As Boolean
    HasUtf8Bom = FileHasBom(strFilePath, UTF8_BOM)
End Function


'---------------------------------------------------------------------------------------
' Procedure : HasUcs2Bom
' Author    : Adam Waller
' Date      : 8/1/2020
' Purpose   : Returns true if the file begins with
'---------------------------------------------------------------------------------------
'
Public Function HasUcs2Bom(strFilePath As String) As Boolean
    HasUcs2Bom = FileHasBom(strFilePath, UCS2_BOM)
End Function


'---------------------------------------------------------------------------------------
' Procedure : FileHasBom
' Author    : Adam Waller
' Date      : 8/1/2020
' Purpose   : Check for the specified BOM
'---------------------------------------------------------------------------------------
'
Private Function FileHasBom(strFilePath As String, strBom As String) As Boolean
    ' Only read the first bytes to check for BOM
    With New ADODB.Stream
        .Type = adTypeBinary
        .Open
        .LoadFromFile strFilePath
        ' Check for BOM
        Dim fileBytes() As Byte
        fileBytes = .Read(Len(strBom))
        FileHasBom = (strBom = StrConv(fileBytes, vbUnicode))
        .Close
    End With
End Function


'---------------------------------------------------------------------------------------
' Procedure : RemoveUTF8BOM
' Author    : Adam Kauffman
' Date      : 1/24/2019
' Purpose   : Will remove a UTF8 BOM from the start of the string passed in.
'---------------------------------------------------------------------------------------
'
Public Function RemoveUTF8BOM(ByVal fileContents As String) As String
    Dim UTF8BOM As String
    UTF8BOM = Chr$(239) & Chr$(187) & Chr$(191) ' == &HEFBBBF
    Dim fileBOM As String
    fileBOM = Left$(fileContents, 3)
    
    If fileBOM = UTF8BOM Then
        RemoveUTF8BOM = Mid$(fileContents, 4)
    Else ' No BOM detected
        RemoveUTF8BOM = fileContents
    End If
End Function


'---------------------------------------------------------------------------------------
' Procedure : BytesLength
' Author    : Casper Englund
' Date      : 2020/05/01
' Purpose   : Return length of byte array
'---------------------------------------------------------------------------------------
Private Function BytesLength(abBytes() As Byte) As Long
    
    ' Ignore error if array is uninitialized
    On Error Resume Next
    BytesLength = UBound(abBytes) - LBound(abBytes) + 1
    If Err.Number <> 0 Then Err.Clear
    On Error GoTo 0
    
End Function


'---------------------------------------------------------------------------------------
' Procedure : Utf8BytesToString
' Author    : Adam Kauffman
' Date      : 2021-03-04
' Purpose   : Return VBA "Unicode" string from byte array encoded in UTF-8
'---------------------------------------------------------------------------------------
Public Function Utf8BytesToString(abUtf8Array() As Byte) As String
    
    With New ADODB.Stream
        .Charset = "UTF-8"
        .Open
        .Type = adTypeBinary
        .Write abUtf8Array
        .Position = 0
        .Type = adTypeText
        Utf8BytesToString = .ReadText(adReadAll)
        .Close
    End With

End Function


'---------------------------------------------------------------------------------------
' Procedure : Utf8BytesFromString
' Author    : Adam Kauffman
' Date      : 2021-03-04
' Purpose   : Return byte array with VBA "Unicode" string encoded in UTF-8
'---------------------------------------------------------------------------------------
Public Function Utf8BytesFromString(strInput As String) As Byte()
    
    With New ADODB.Stream
        .Charset = "UTF-8"
        .Open
        .Type = adTypeText
        .WriteText strInput
        .Position = 0
        .Type = adTypeBinary
        Utf8BytesFromString = .Read(adReadAll)
        .Close
    End With
       
End Function


'---------------------------------------------------------------------------------------
' Procedure : ReadFile
' Author    : Adam Waller / Indigo
' Date      : 11/4/2020
' Purpose   : Read text file.
'           : Read in UTF-8 encoding, removing a BOM if found at start of file.
'---------------------------------------------------------------------------------------
'
Public Function ReadFile(strPath As String, Optional strCharset As String = "UTF-8") As String

    Dim strText As String
    Dim cData As clsConcat
    Dim strBom As String
    
    ' Get BOM header, if applicable
    Select Case strCharset
        Case "UTF-8": strBom = UTF8_BOM
        Case "Unicode": strBom = UCS2_BOM
    End Select
    
    If FSO.FileExists(strPath) Then
        Perf.OperationStart "Read File"
        Set cData = New clsConcat
        With New ADODB.Stream
            .Charset = strCharset
            .Open
            .LoadFromFile strPath
            ' Check for BOM
            If strBom <> vbNullString Then
                strText = .ReadText(Len(strBom))
                If strText <> strBom Then cData.Add strText
            End If
            ' Read chunks of text, rather than the whole thing at once for massive
            ' performance gains when reading large files.
            ' See https://docs.microsoft.com/is-is/sql/ado/reference/ado-api/readtext-method
            Do While Not .EOS
                cData.Add .ReadText(131072) ' 128K
            Loop
            .Close
        End With
        Perf.OperationEnd
    End If
    
    ' Return text contents of file.
    ReadFile = cData.GetStr
    
End Function


'---------------------------------------------------------------------------------------
' Procedure : WriteFile
' Author    : Adam Waller
' Date      : 1/23/2019
' Purpose   : Save string variable to text file. (Building the folder path if needed)
'           : Saves in UTF-8 encoding, adding a BOM if extended or unicode content
'           : is found in the file. https://stackoverflow.com/a/53036838/4121863
'---------------------------------------------------------------------------------------
'
Public Sub WriteFile(strText As String, strPath As String)

    Dim strContent As String
    Dim bteUtf8() As Byte
    
    ' Ensure that we are ending the content with a vbcrlf
    strContent = strText
    If Right$(strText, 2) <> vbCrLf Then strContent = strContent & vbCrLf

    ' Build a byte array from the text
    bteUtf8 = Utf8BytesFromString(strContent)
    
    ' Write binary content to file.
    WriteBinaryFile bteUtf8, True, strPath
        
End Sub


'---------------------------------------------------------------------------------------
' Procedure : WriteBinaryFile
' Author    : Adam Waller
' Date      : 8/3/2020
' Purpose   : Write binary content to a file with optional UTF-8 BOM.
'---------------------------------------------------------------------------------------
'
Public Sub WriteBinaryFile(bteContent() As Byte, blnUtf8Bom As Boolean, strPath As String)

    Dim bteBOM(0 To 2) As Byte
    
    ' Write to a binary file using a Stream object
    With New ADODB.Stream
        .Type = adTypeBinary
        .Open
        If blnUtf8Bom Then
            bteBOM(0) = &HEF
            bteBOM(1) = &HBB
            bteBOM(2) = &HBF
            .Write bteBOM
        End If
        
        .Write bteContent
        VerifyPath strPath
        Perf.OperationStart "Write to Disk"
        .SaveToFile strPath, adSaveCreateOverWrite
        Perf.OperationEnd
        .Close
    End With
    
End Sub


'---------------------------------------------------------------------------------------
' Procedure : StringHasExtendedASCII
' Author    : Adam Waller
' Date      : 3/6/2020
' Purpose   : Returns true if the string contains non-ASCI characters.
'---------------------------------------------------------------------------------------
'
Public Function StringHasExtendedASCII(strText As String) As Boolean

    Perf.OperationStart "Unicode Check"
    With New VBScript_RegExp_55.RegExp
        ' Include extended ASCII characters here.
        .Pattern = "[^\u0000-\u007F]"
        StringHasExtendedASCII = .Test(strText)
    End With
    Perf.OperationEnd
    
End Function


'---------------------------------------------------------------------------------------
' Procedure : ReEncodeFile
' Author    : Adam Kauffman
' Date      : 3/4/2021
' Purpose   : Change File Encoding. It reads and writes at the same time so the files must be different.
'               intOverwriteMode will take the following values:
'                   Const adSaveCreateOverWrite = 2
'                   Const adSaveCreateNotExist = 1
'---------------------------------------------------------------------------------------
'
Public Sub ReEncodeFile(strInputFile, strInputCharset, strOutputFile, strOutputCharset, intOverwriteMode)

    Dim objOutputStream As ADODB.Stream
    Set objOutputStream = New ADODB.Stream
    
    With New ADODB.Stream
        .Open
        .Type = adTypeBinary
        .LoadFromFile strInputFile
        .Type = adTypeText
        .Charset = strInputCharset
        objOutputStream.Open
        objOutputStream.Charset = strOutputCharset
        Do While .EOS <> True
            objOutputStream.WriteText .ReadText(adReadLine), adWriteLine
        Loop
        
        .Close
    End With
    
    objOutputStream.SaveToFile strOutputFile, intOverwriteMode
    objOutputStream.Close
End Sub